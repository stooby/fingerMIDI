//
//  AudioEngine.mm
//  fingerMIDI
//
//  Created by Scott Tooby on 5/23/26.
//

#import "AudioEngine.h"
#import <AVFoundation/AVFoundation.h>
#include "rnbo/RNBO.h"
#include "rnbo_snare-kick-detector.cpp"   // generated RNBO patch file
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <set>
#include <vector>

// Capacity of the lock-free SPSC ring buffers that hand real-time events (MIDI
// note events, and later a spectral-message capture) from the audio render thread
// to the main thread without allocating or locking on the audio thread. Power of
// two so index wrap is a bitmask, not a modulo. Sized to absorb several seconds
// of main-thread unresponsiveness at the onset detector's max rate before it
// drops (drop-newest).
static constexpr size_t kEventRingCapacity = 2048;

// The RNBO patch's onset-detection / processing latency in ms — the delay between
// an audio onset and RNBO emitting its MIDI event. This is the single source of
// truth for that figure: it (a) sizes the post-seek MIDI settling window (Step
// 14.35) here on the audio thread, and (b) is exposed to Swift via
// -processingLatencyMs so WaveformView can left-shift MIDI blocks into alignment
// with the waveform. Hardcoded placeholder for now; a future update will feed it
// from the patch's `processingLatency` outport message.
static constexpr double kRnboProcessingLatencyMs = 40.0;

// A real-time MIDI event already converted to a file-relative timestamp on the
// audio thread. Carries the raw 1–3 status bytes
// plus fileMs, so the main-thread consumer does no anchor math and a later seek
// cannot retroactively re-time it.
struct RtMidiEvent {
    double  fileMs;
    uint8_t bytes[3];
    uint8_t len;
};

// Feature discriminator for a captured spectral outport message. Plain int so the
// audio thread never touches an NSString/ObjC object. Kept in sync with the Swift
// side (ParameterStore.SpectralFeature): 0 = SpectralCentroid, 1 = SpectralFlatness.
enum SpectralFeature : int {
    SpectralFeatureCentroid = 0,
    SpectralFeatureFlatness = 1,
};

// A spectral outport message reduced to plain-old-data on the audio thread — the
// only thing written into MessageEventCapture's lock-free ring. No ObjC, no ARC.
struct SpectralMsg {
    int    feature;   // SpectralFeature
    double value;
};

// ---------------------------------------------------------------------------
// MIDI event accumulator (real-time safe)
//
// Subclasses RNBO::EventHandler to capture outgoing MidiEvents from the RNBO
// patch. handleMidiEvent() runs on whatever thread calls drain() after
// process(): the audio render thread during real-time playback, or the offline
// render thread during export. Those two paths have opposite needs, so the
// capture keeps two separate buffers and routes by _offlineMode:
//
//  • Real-time path (default): a lock-free single-producer / single-consumer
//    ring of RtMidiEvent. Each event's file-relative timestamp is computed on
//    the audio thread from the producing block's playhead + RNBO-time base
//    (setBlockBase), so a concurrent seek can never retroactively
//    re-time it and the main-thread consumer does no anchor math. The producer
//    never allocates and never locks; on overflow it drops the newest event
//    (drop-newest keeps the producer off the consumer-owned read index,
//    preserving strict SPSC). Overflow is acceptable — the overlay is a
//    best-effort preview; the authoritative MIDI is the offline export. Drained
//    by drainRealTimeRing() on the main thread.
//
//  • Offline path (_offlineMode == true): the original mutex-guarded vector of
//    raw RNBO::MidiEvent, unchanged. Offline export must be lossless, but it runs
//    on a background thread with no real-time deadline, so malloc and the mutex
//    are fine (and the mutex is uncontended — producer and consumer are the same
//    offline thread). Drained by collectAndClear(); timestamps normalised later
//    via _offlineRenderStartMs.
//
//  • _offlineMode is toggled around offline renders (true in
//    -stopForOfflineRender, false in -resumeAfterOfflineRender before the engine
//    restarts) and read memory_order_relaxed on the audio thread.
//
//  • eventsAvailable() is a no-op — we call drain() explicitly after each
//    process(). drain() is a thin wrapper around EventHandler::drainEvents().
//
//  • resetRealTimeRing() discards buffered real-time events; called from
//    -beginRealTimeCapture (play start / seek) so each fresh timeline starts
//    clean (a UX choice — surviving events are already correctly timed).
// ---------------------------------------------------------------------------
class MidiEventCapture : public RNBO::EventHandler {
public:
    // Called from within process() on the audio (or offline) thread — a no-op.
    void eventsAvailable() override {}

    // Set by the render block once per block, BEFORE drain(), so handleMidiEvent
    // can convert each real-time event to a file-relative timestamp using this
    // block's playhead (fileMs) and RNBO-time (rnboMs) base. Producer-thread only
    // (written and read on the same audio thread), so no atomics are needed.
    void setBlockBase(double fileMs, double rnboMs, double totalMs) {
        _blockBaseFileMs = fileMs;
        _blockBaseRnboMs = rnboMs;
        _blockTotalMs    = totalMs;
        // A seek arms a post-seek settling window: from this block
        // until rnboMs + kRnboProcessingLatencyMs, drop real-time MIDI events so
        // RNBO's in-flight (pre-seek) onsets and the seek discontinuity's
        // false-triggers aren't stamped at the new playhead. exchange() consumes
        // the one-shot arm flag; the deadline is audio-thread-local thereafter.
        if (_armSeekSettle.exchange(false, std::memory_order_acquire))
            _settleUntilRnboMs = rnboMs + kRnboProcessingLatencyMs;
    }

    void handleMidiEvent(const RNBO::MidiEvent& event) override {
        if (_offlineMode.load(std::memory_order_relaxed)) {
            // Offline export — lossless; malloc/lock are fine off the audio thread.
            std::lock_guard<std::mutex> lock(_mutex);
            _events.push_back(event);
            return;
        }
        // Post-seek settling window: while this block's RNBO time is
        // within kRnboProcessingLatencyMs of the last seek, drop events — they are
        // RNBO's in-flight pre-seek onsets or the seek discontinuity's false-triggers.
        if (_blockBaseRnboMs < _settleUntilRnboMs) return;

        // Real-time render thread — lock-free SPSC ring, drop-newest on full.
        const size_t w    = _writeIdx.load(std::memory_order_relaxed);
        const size_t next = (w + 1) & (kEventRingCapacity - 1);
        if (next == _readIdx.load(std::memory_order_acquire))
            return;                                  // ring full — drop newest

        // Convert to a file-relative timestamp here, on the audio thread, using
        // the base for the block that produced this event. fmod wraps
        // events past the loop boundary back into [0, totalMs).
        double fileMs = _blockBaseFileMs + (event.getTime() - _blockBaseRnboMs);
        if (_blockTotalMs > 0.0) fileMs = std::fmod(fileMs, _blockTotalMs);

        RtMidiEvent &slot = _ring[w];
        slot.fileMs   = fileMs;
        slot.len      = (uint8_t)event.getLength();
        const uint8_t *src = event.getData();
        slot.bytes[0] = src[0];
        slot.bytes[1] = src[1];
        slot.bytes[2] = src[2];
        _writeIdx.store(next, std::memory_order_release);
    }

    // Public wrapper for the protected drainEvents(); call after each process().
    void drain() { drainEvents(); }

    // --- Real-time path (main-thread consumer) -----------------------------

    // Drains the lock-free ring into a vector allocated on the main thread
    // (never on the producer side). Called by -collectAndClearRealTimeMidiEvents.
    std::vector<RtMidiEvent> drainRealTimeRing() {
        std::vector<RtMidiEvent> out;
        const size_t w = _writeIdx.load(std::memory_order_acquire);
        size_t r = _readIdx.load(std::memory_order_relaxed);
        while (r != w) {
            out.push_back(_ring[r]);
            r = (r + 1) & (kEventRingCapacity - 1);
        }
        _readIdx.store(w, std::memory_order_release);
        return out;
    }

    // Discards all buffered real-time events (main thread). Consumer-side only —
    // advances the read index to the current write index, so it is safe to call
    // while the producer runs. Called from -beginRealTimeCapture.
    void resetRealTimeRing() {
        _readIdx.store(_writeIdx.load(std::memory_order_acquire),
                       std::memory_order_release);
    }

    // Arm a post-seek settling window (main thread; from -setPlayheadPosition). The
    // audio thread turns it into an RNBO-time deadline on its next block.
    void armSeekSettle() { _armSeekSettle.store(true, std::memory_order_release); }

    // --- Offline path (background-thread producer + consumer) --------------

    // Toggled around offline renders (main thread). Routes handleMidiEvent to
    // the lossless mutex+vector buffer while true.
    void setOfflineMode(bool enabled) {
        _offlineMode.store(enabled, std::memory_order_release);
    }

    // Returns all events accumulated in the offline buffer and clears it.
    std::vector<RNBO::MidiEvent> collectAndClear() {
        std::lock_guard<std::mutex> lock(_mutex);
        std::vector<RNBO::MidiEvent> out;
        out.swap(_events);
        return out;
    }

private:
    // Real-time path: lock-free SPSC ring of already-timestamped events. Producer
    // (audio thread) owns _writeIdx; consumer (main thread) owns _readIdx.
    RtMidiEvent          _ring[kEventRingCapacity]{};
    std::atomic<size_t>  _writeIdx{0};
    std::atomic<size_t>  _readIdx{0};

    // Per-block conversion base, written & read only on the audio (producer)
    // thread — set by setBlockBase() before each drain(), read in handleMidiEvent.
    double _blockBaseFileMs = 0.0;
    double _blockBaseRnboMs = 0.0;
    double _blockTotalMs    = 0.0;

    // Post-seek settling window. _armSeekSettle: one-shot main→audio
    // signal set by armSeekSettle(). _settleUntilRnboMs: audio-thread-local RNBO-time
    // deadline; real-time events whose block base precedes it are dropped.
    std::atomic<bool> _armSeekSettle{false};
    double            _settleUntilRnboMs = 0.0;

    // Offline path: lossless mutex-guarded vector of raw events.
    std::mutex                   _mutex;
    std::vector<RNBO::MidiEvent> _events;

    // Routes handleMidiEvent: ring (false, real-time) vs vector (true, offline).
    std::atomic<bool>    _offlineMode{false};
};

// ---------------------------------------------------------------------------
// Parameter event listener
//
// Subclasses RNBO::EventHandler to capture parameter value changes from the
// RNBO patch. Used to mirror patch-internal parameter writes (e.g. the
// SpecFlatCutoff and SpecCentCutoff values computed when the EnableTraining
// feature runs) back into the SwiftUI parameter store so the UI display
// updates and subsequent pushAllValuesToEngine() calls don't clobber them.
//
// Design notes:
//
//  • Registered on a second ParameterEventInterface (separate from the MIDI
//    one) per RNBO's "one handler per interface" API. Both interfaces receive
//    the same outgoing events; this class ignores everything except the
//    indices it has been told to watch.
//
//  • eventsAvailable() is a no-op; drain() is called explicitly from the
//    audio render block after every process(), matching the MidiEventCapture
//    pattern. handleParameterEvent() therefore runs on the audio thread.
//
//  • Feedback-loop avoidance: every host-initiated write is routed through
//    AudioEngine's _paramEventInterface (NOT _coreObject directly), so those
//    events come back tagged with that interface's pointer as their source.
//    The hostInterfaceId filter drops them so a user-driven rotary change to
//    SpecFlatCutoff / SpecCentCutoff doesn't ping-pong an extra UI update.
//
//  • Watched-index filtering keeps the dispatch_async fast path off the hook
//    for unrelated parameter events. Both the watched set and the host
//    interface id are written once at AudioEngine init (before the audio
//    engine starts), then read-only from the audio thread — no locking needed.
//
//  • The Objective-C callback block is invoked via dispatch_async on the main
//    queue, so the SwiftUI ParameterStore handler runs on the main thread.
//
//  • paramEventsDeliveryEnabled is toggled false around offline renders to
//    suppress reset-bang events (from prepareToProcess(reset=true)) and any
//    in-flight events from leaking into the UI after the render completes.
// ---------------------------------------------------------------------------
class ParameterEventCapture : public RNBO::EventHandler {
public:
    using ParamChangeBlock = void (^)(RNBO::ParameterIndex index, RNBO::ParameterValue value);

    void eventsAvailable() override {}

    void handleParameterEvent(const RNBO::ParameterEvent& event) override {
        if (!_deliveryEnabled.load(std::memory_order_acquire)) return;
        if (event.getSource() == _hostInterfaceId) return;
        if (_watchedParamIndices.find(event.getIndex()) == _watchedParamIndices.end()) return;

        ParamChangeBlock block = _paramChangeBlock;
        if (!block) return;

        RNBO::ParameterIndex index = event.getIndex();
        RNBO::ParameterValue value = event.getValue();
        dispatch_async(dispatch_get_main_queue(), ^{
            block(index, value);
        });
    }

    void drain() { drainEvents(); }

    // Configuration — call once at init, before the audio engine starts.
    void setHostInterfaceId(RNBO::ParameterInterfaceId id) { _hostInterfaceId = id; }
    void setWatchedParamIndices(std::set<RNBO::ParameterIndex> indices) {
        _watchedParamIndices = std::move(indices);
    }
    void setParamChangeBlock(ParamChangeBlock block) { _paramChangeBlock = block; }

    // Toggled around offline renders (main thread).
    void setDeliveryEnabled(bool enabled) {
        _deliveryEnabled.store(enabled, std::memory_order_release);
    }

private:
    RNBO::ParameterInterfaceId     _hostInterfaceId = nullptr;
    std::set<RNBO::ParameterIndex> _watchedParamIndices;
    ParamChangeBlock               _paramChangeBlock = nil;
    std::atomic<bool>              _deliveryEnabled{true};
};

// ---------------------------------------------------------------------------
// Spectral message listener (real-time safe, pull model)
//
// Subclasses RNBO::EventHandler to capture the patch's per-onset SpectralCentroid
// and SpectralFlatness outport messages and hand them to the UI histogram. Like
// MidiEventCapture, handleMessageEvent() runs on the audio render thread (drained
// right after process()), so it must not allocate, lock, or touch ARC. It therefore
// follows the MIDI capture's PULL model — NOT ParameterEventCapture's dispatch_async
// push. Spectral messages fire twice per detected onset (Centroid + Flatness),
// continuously during live playback and clustered at transients (when the render
// block is busiest); a Block_copy(malloc)+libdispatch lock per onset there would risk
// audible dropouts. Instead the audio thread reduces each survivor to a POD
// SpectralMsg and writes it into a lock-free single-producer/single-consumer ring;
// the main thread pulls the batch on a timer via -collectAndClearSpectralEvents.
//
//  • Same ring design as MidiEventCapture's real-time path (shared kEventRingCapacity
//    constant, drop-newest on overflow) but a SEPARATE buffer of SpectralMsg slots.
//    The histogram is a best-effort live display, so drop-newest loss is harmless.
//
//  • No offline buffer and no per-block timestamp/settling machinery — spectral has
//    no lossless offline consumer, and the values carry no timeline.
//
//  • _deliveryEnabled is toggled false around offline renders so Analyze Onsets /
//    Export MIDI don't populate the live histogram; resetRing() discards buffered
//    real-time samples at the offline boundary so none bleed across.
//
//  • eventsAvailable() is a no-op; drain() is called explicitly after each process().
// ---------------------------------------------------------------------------
class MessageEventCapture : public RNBO::EventHandler {
public:
    void eventsAvailable() override {}

    void handleMessageEvent(const RNBO::MessageEvent& event) override {
        if (!_deliveryEnabled.load(std::memory_order_acquire)) return;
        if (event.getType() != RNBO::MessageEvent::Number) return;

        int feature = SpectralFeatureCentroid;
        const RNBO::MessageTag tag = event.getTag();
        if      (tag == RNBO::TAG("SpectralCentroid")) feature = SpectralFeatureCentroid;
        else if (tag == RNBO::TAG("SpectralFlatness")) feature = SpectralFeatureFlatness;
        else return;

        // Real-time render thread — lock-free SPSC ring, drop-newest on full.
        const size_t w    = _writeIdx.load(std::memory_order_relaxed);
        const size_t next = (w + 1) & (kEventRingCapacity - 1);
        if (next == _readIdx.load(std::memory_order_acquire))
            return;                                  // ring full — drop newest

        SpectralMsg &slot = _ring[w];
        slot.feature = feature;
        slot.value   = (double)event.getNumValue();
        _writeIdx.store(next, std::memory_order_release);
    }

    // Public wrapper for the protected drainEvents(); call after each process().
    void drain() { drainEvents(); }

    // Drains the lock-free ring into a vector allocated on the main thread (never on
    // the producer side). Called by -collectAndClearSpectralEvents.
    std::vector<SpectralMsg> drainRing() {
        std::vector<SpectralMsg> out;
        const size_t w = _writeIdx.load(std::memory_order_acquire);
        size_t r = _readIdx.load(std::memory_order_relaxed);
        while (r != w) {
            out.push_back(_ring[r]);
            r = (r + 1) & (kEventRingCapacity - 1);
        }
        _readIdx.store(w, std::memory_order_release);
        return out;
    }

    // Discards all buffered samples (main thread). Consumer-side only — advances the
    // read index to the current write index, safe while the producer runs. Called at
    // the offline-render boundary so no real-time-phase samples bleed across it.
    void resetRing() {
        _readIdx.store(_writeIdx.load(std::memory_order_acquire),
                       std::memory_order_release);
    }

    // Toggled around offline renders (main thread) so offline spectral messages don't
    // reach the ring and populate the live histogram.
    void setDeliveryEnabled(bool enabled) {
        _deliveryEnabled.store(enabled, std::memory_order_release);
    }

private:
    // Producer (audio thread) owns _writeIdx; consumer (main thread) owns _readIdx.
    SpectralMsg          _ring[kEventRingCapacity]{};
    std::atomic<size_t>  _writeIdx{0};
    std::atomic<size_t>  _readIdx{0};
    std::atomic<bool>    _deliveryEnabled{true};
};

// Safe upper bound for any macOS hardware buffer size; passed to
// prepareToProcess() so RNBO pre-allocates its internal working memory.
static const AVAudioFrameCount kMaxFrames = 4096;

// Block size used for offline rendering. Smaller than the real-time buffer to
// maximise timestamp resolution for onset detection (≈1.45 ms at 44.1 kHz).
static const AVAudioFrameCount kOfflineBlockSize = 64;

// ---------------------------------------------------------------------------
// Live recording waveform accumulator (Step 9)
//
// Builds a scrolling min/max envelope of the incoming live-input signal over a
// fixed 60-second window, for the red "recording" waveform. Fed from the input
// tap block — which, unlike the AVAudioSourceNode render block, tolerates the
// small mutex used here to hand a consistent snapshot to the main thread (the tap
// is the standard place to do file I/O and light compute). Left channel only,
// matching the static file thumbnail. When recording passes a 60 s boundary the
// bins are cleared and refilled from the left, so the display "scrolls" by wrapping.
// ---------------------------------------------------------------------------
struct LiveWaveform {
    static constexpr int    kBinCount     = 2048;
    static constexpr double kWindowSeconds = 60.0;

    std::mutex mutex;
    float   minBins[kBinCount];
    float   maxBins[kBinCount];
    bool    binHasData[kBinCount];
    double  sampleRate   = 44100.0;
    int64_t windowFrames = (int64_t)(kWindowSeconds * 44100.0);
    int64_t windowStart  = 0;   // global recorded-frame index at the start of the current window
    int64_t windowIndex  = 0;

    void clearBinsLocked() { std::memset(binHasData, 0, sizeof(binHasData)); }

    // Reset for a new recording session (main thread; no tap running yet).
    void reset(double sr) {
        std::lock_guard<std::mutex> lock(mutex);
        sampleRate   = sr > 0.0 ? sr : 44100.0;
        windowFrames = (int64_t)(kWindowSeconds * sampleRate);
        if (windowFrames < 1) windowFrames = 1;
        windowStart  = 0;
        windowIndex  = 0;
        clearBinsLocked();
    }

    // Fold a tap buffer's left channel into the bins (tap thread). `bufStart` is the
    // global recorded-frame index of sample 0 in this buffer.
    void addSamples(const float *L, int64_t n, int64_t bufStart) {
        std::lock_guard<std::mutex> lock(mutex);
        if (windowFrames < 1) return;
        for (int64_t i = 0; i < n; ++i) {
            int64_t into = (bufStart + i) - windowStart;
            while (into >= windowFrames) {          // crossed the 60 s boundary
                windowStart += windowFrames;
                windowIndex += 1;
                clearBinsLocked();
                into -= windowFrames;
            }
            if (into < 0) continue;                  // monotonic recording — shouldn't happen
            int idx = (int)(into * kBinCount / windowFrames);
            if (idx < 0) idx = 0; else if (idx >= kBinCount) idx = kBinCount - 1;
            float s = L[i];
            if (!binHasData[idx]) { minBins[idx] = s; maxBins[idx] = s; binHasData[idx] = true; }
            else { if (s < minBins[idx]) minBins[idx] = s; if (s > maxBins[idx]) maxBins[idx] = s; }
        }
    }

    // Copy the current bins into `out` (2*kBinCount floats: min,max pairs). No-data
    // bins are written as (0, 0); the view only draws up to the live playhead anyway.
    void copyBins(float *out) {
        std::lock_guard<std::mutex> lock(mutex);
        for (int i = 0; i < kBinCount; ++i) {
            out[2 * i]     = binHasData[i] ? minBins[i] : 0.0f;
            out[2 * i + 1] = binHasData[i] ? maxBins[i] : 0.0f;
        }
    }
};

@implementation AudioEngine {
    RNBO::CoreObject   _coreObject;
    AVAudioEngine     *_engine;
    AVAudioSourceNode *_sourceNode;
    RNBO::SampleValue *_inL;
    RNBO::SampleValue *_inR;
    RNBO::SampleValue *_outL;
    RNBO::SampleValue *_outR;

    // PCM host buffer (stereo float at engine sample rate, loaded from file).
    std::atomic<float *>  _pcmL;
    std::atomic<float *>  _pcmR;
    std::atomic<int64_t>  _pcmFrameCount;
    std::atomic<int64_t>  _playhead;

    // Gates whether PCM data is fed to RNBO. When false the render block sends
    // silence to RNBO so effects tails (delay, reverb, etc.) ring out naturally.
    std::atomic<bool> _isPlaying;

    // Cached hardware sample rate — queried once at init.
    double _engineSampleRate;

    // Live input recording (Step 9 — Workflow 2b, no monitoring). The tap block
    // (Branch A) writes to _recordFile and updates _recordedFrames + _liveWaveform.
    AVAudioFile          *_recordFile;      // nil unless recording
    NSURL                *_recordURL;       // temp file being written
    std::atomic<bool>     _isRecording;
    std::atomic<int64_t>  _recordedFrames;  // frames captured since record start
    LiveWaveform          _liveWaveform;    // scrolling 60 s red-waveform accumulator

    // MIDI event capture. _midiCapture must outlive _paramEventInterface
    // (the interface holds a raw pointer to the handler); see -dealloc.
    MidiEventCapture                       _midiCapture;
    RNBO::ParameterEventInterfaceUniquePtr _paramEventInterface;

    // Parameter event listener. Receives notifications when the RNBO patch
    // internally writes to watched parameters (currently SpecFlatCutoff and
    // SpecCentCutoff after EnableTraining runs) and forwards them to the
    // Swift layer via -parameterChangeHandler. _paramCapture must outlive
    // _paramListenerInterface (the interface holds a raw pointer); see -dealloc.
    ParameterEventCapture                  _paramCapture;
    RNBO::ParameterEventInterfaceUniquePtr _paramListenerInterface;

    // Spectral message listener. Captures the patch's per-onset SpectralCentroid /
    // SpectralFlatness outport messages into a lock-free ring, pulled by the Swift
    // layer for the histogram display. _messageCapture must outlive
    // _messageListenerInterface (the interface holds a raw pointer); see -dealloc.
    MessageEventCapture                    _messageCapture;
    RNBO::ParameterEventInterfaceUniquePtr _messageListenerInterface;

    // True while an offline render owns CoreObject (the engine is intentionally
    // stopped). Read by the configuration-change handler so it never restarts the
    // engine underneath the offline loop.
    std::atomic<bool> _offlineRenderActive;

    // Absolute RNBO engine time (ms) at the start of the most recent offline
    // render main loop. RNBO's time counter is cumulative and is not reset by
    // prepareToProcess, so event timestamps must be normalised by subtracting
    // this offset to produce file-relative times.
    RNBO::MillisecondTime _offlineRenderStartMs;

    // Real-time MIDI timestamps are converted to file-relative ms on the audio
    // thread, per block (MidiEventCapture::setBlockBase), so there is
    // no cross-thread playback anchor to store here.
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Wire the MIDI event handler to CoreObject. SingleProducer gives us a
        // lock-free queue between the audio thread (producer) and our drain()
        // calls (consumer). The returned interface must be kept alive as long as
        // we want events; it is reset in -dealloc before _midiCapture is destroyed.
        //
        // _paramEventInterface also serves as the host-write interface: all
        // -setParameterWithIndex:value: / -setParameterWithId:value: calls route
        // through it (rather than _coreObject) so the resulting parameter events
        // come back tagged with this interface's pointer as their source. That
        // identity is what _paramCapture filters on to drop self-writes.
        _paramEventInterface = _coreObject.createParameterInterface(
            RNBO::ParameterEventInterface::SingleProducer,
            &_midiCapture
        );

        // Wire the parameter-change listener to CoreObject. Separate interface,
        // separate handler, drained alongside the MIDI one in the render block.
        _paramListenerInterface = _coreObject.createParameterInterface(
            RNBO::ParameterEventInterface::SingleProducer,
            &_paramCapture
        );

        // Wire the spectral message listener to CoreObject. A third interface /
        // handler, drained alongside the other two after every process(). Overrides
        // only handleMessageEvent, so it ignores MIDI and parameter events.
        _messageListenerInterface = _coreObject.createParameterInterface(
            RNBO::ParameterEventInterface::SingleProducer,
            &_messageCapture
        );

        // Tell _paramCapture which interface's events to treat as self-writes
        // (everything we send via _paramEventInterface->setParameterValue), and
        // which parameter indices it should care about. SpecFlatCutoff and
        // SpecCentCutoff are set internally by the patch after EnableTraining
        // runs; if either is missing from the patch we just skip it.
        _paramCapture.setHostInterfaceId(
            (RNBO::ParameterInterfaceId)_paramEventInterface.get()
        );
        std::set<RNBO::ParameterIndex> watched;
        for (NSString *paramId in @[@"SpecFlatCutoff", @"SpecCentCutoff"]) {
            RNBO::ParameterIndex idx =
                _coreObject.getParameterIndexForID(paramId.UTF8String);
            if (idx != RNBO::INVALID_INDEX) watched.insert(idx);
            else NSLog(@"[AudioEngine] watched param '%@' not found in patch", paramId);
        }
        _paramCapture.setWatchedParamIndices(std::move(watched));

        _isRecording.store(false, std::memory_order_relaxed);
        _recordedFrames.store(0, std::memory_order_relaxed);
        _offlineRenderActive.store(false, std::memory_order_relaxed);

        [self setupEngine];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_engine stop];
    // Reset interfaces before their handlers are destroyed (interfaces hold raw pointers).
    _messageListenerInterface.reset();
    _paramListenerInterface.reset();
    _paramEventInterface.reset();
    delete[] _inL;
    delete[] _inR;
    delete[] _outL;
    delete[] _outR;
}

- (void)setParameterChangeHandler:(void (^)(int, float))handler {
    _parameterChangeHandler = [handler copy];
    // Adapt the host-friendly (int, float) signature to the C++ types
    // ParameterEventCapture expects internally.
    void (^block)(int, float) = _parameterChangeHandler;
    if (block) {
        _paramCapture.setParamChangeBlock(^(RNBO::ParameterIndex index,
                                            RNBO::ParameterValue value) {
            block((int)index, (float)value);
        });
    } else {
        _paramCapture.setParamChangeBlock(nil);
    }
}

// Sets up AVAudioEngine, RNBO, and the source node. Called once from -init.
- (void)setupEngine {
    _engine = [[AVAudioEngine alloc] init];

    double sr = [_engine.outputNode outputFormatForBus:0].sampleRate;
    _engineSampleRate = sr > 0.0 ? sr : 44100.0;

    _inL  = new RNBO::SampleValue[kMaxFrames];
    _inR  = new RNBO::SampleValue[kMaxFrames];
    _outL = new RNBO::SampleValue[kMaxFrames];
    _outR = new RNBO::SampleValue[kMaxFrames];

    _coreObject.prepareToProcess(_engineSampleRate, kMaxFrames);
    [self loadRNBODataRefs];
    // Parameter values are applied by the Swift layer (ParameterStore.pushAllValuesToEngine)
    // on the first Play press, so no host-side defaults are pushed here.

    // Capture raw pointers — no ObjC message sends or ARC retains on the audio thread.
    RNBO::CoreObject     *core           = &_coreObject;
    MidiEventCapture     *midiCapture    = &_midiCapture;
    ParameterEventCapture *paramCapture  = &_paramCapture;
    MessageEventCapture  *messageCapture = &_messageCapture;
    RNBO::SampleValue    *inL            = _inL;
    RNBO::SampleValue    *inR            = _inR;
    RNBO::SampleValue    *outL           = _outL;
    RNBO::SampleValue    *outR           = _outR;
    std::atomic<float *> *pcmLPtr        = &_pcmL;
    std::atomic<float *> *pcmRPtr        = &_pcmR;
    std::atomic<int64_t> *framesPtr      = &_pcmFrameCount;
    std::atomic<int64_t> *headPtr        = &_playhead;
    std::atomic<bool>    *isPlayingPtr        = &_isPlaying;
    double                sampleRate          = _engineSampleRate;

    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:_engineSampleRate channels:2];

    _sourceNode = [[AVAudioSourceNode alloc]
        initWithFormat:format
        renderBlock:^OSStatus(BOOL *isSilence,
                              const AudioTimeStamp *timestamp,
                              AVAudioFrameCount frameCount,
                              AudioBufferList *outputData) {

            float   *pcmL   = pcmLPtr->load(std::memory_order_acquire);
            float   *pcmR   = pcmRPtr->load(std::memory_order_acquire);
            int64_t  total  = framesPtr->load(std::memory_order_relaxed);
            int64_t  pos    = headPtr->load(std::memory_order_relaxed);
            bool     playing = isPlayingPtr->load(std::memory_order_relaxed);

            // Normalise the playhead once (guards against pos at/past total from an
            // external setPlayheadPosition right at the file boundary), then hand the
            // MIDI capture this block's timestamp base BEFORE process() advances RNBO
            // time. Pairing THIS block's playhead (fileMs) with its RNBO-time base lets
            // handleMidiEvent stamp events with file-relative time on the audio thread —
            // immune to concurrent seeks.
            if (total > 0 && pos >= total) pos %= total;
            double blockBaseFileMs = (sampleRate > 0.0) ? (double)pos / sampleRate * 1000.0 : 0.0;
            double blockTotalMs    = (sampleRate > 0.0) ? (double)total / sampleRate * 1000.0 : 0.0;
            midiCapture->setBlockBase(blockBaseFileMs, core->getCurrentTime(), blockTotalMs);

            if (playing && pcmL != nullptr && total > 0) {
                // pos already normalised above.

                // Fill RNBO input with seamless loop wrap.
                // Single-subtract wrap is sufficient because pos < total and
                // frameCount <= total (true for any file longer than one block).
                for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                    int64_t f = pos + (int64_t)i;
                    if (f >= total) f -= total;
                    inL[i] = (RNBO::SampleValue)pcmL[f];
                    inR[i] = (RNBO::SampleValue)pcmR[f];
                }
                int64_t newHead = pos + (int64_t)frameCount;
                if (newHead >= total) newHead -= total;
                headPtr->store(newHead, std::memory_order_relaxed);
            } else {
                // Stopped or no file loaded — feed silence so effects tails ring out.
                memset(inL, 0, frameCount * sizeof(RNBO::SampleValue));
                memset(inR, 0, frameCount * sizeof(RNBO::SampleValue));
            }

            // RNBO always processes regardless of transport state.
            RNBO::SampleValue *inBufs[2]  = { inL, inR };
            RNBO::SampleValue *outBufs[2] = { outL, outR };
            core->process(inBufs, 2, outBufs, 2, frameCount);
            midiCapture->drain();
            paramCapture->drain();
            messageCapture->drain();

            UInt32 chCount = outputData->mNumberBuffers;
            for (UInt32 ch = 0; ch < chCount && ch < 2; ++ch) {
                float             *dst = (float *)outputData->mBuffers[ch].mData;
                RNBO::SampleValue *src = outBufs[ch];
                for (AVAudioFrameCount i = 0; i < frameCount; ++i)
                    dst[i] = (float)src[i];
            }
            return noErr;
        }];

    [_engine attachNode:_sourceNode];
    [_engine connect:_sourceNode          to:_engine.mainMixerNode format:format];
    [_engine connect:_engine.mainMixerNode to:_engine.outputNode   format:nil];

    NSError *error = nil;
    if (![_engine startAndReturnError:&error])
        NSLog(@"[AudioEngine] failed to start: %@", error);

    // Recover from audio I/O configuration changes: the user switching the default
    // input/output device, unplugging an interface, or a sample-rate change. On such
    // an event the engine stops itself and can invalidate node connections and taps,
    // which otherwise leaves playback permanently dead (throwing -10877).
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handleConfigurationChange:)
               name:AVAudioEngineConfigurationChangeNotification
             object:_engine];
}

- (void)handleConfigurationChange:(NSNotification *)note {
    // May arrive on an arbitrary thread; serialize the graph rebuild with all other
    // engine operations on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{ [self reconfigureAfterConfigurationChange]; });
}

- (void)reconfigureAfterConfigurationChange {
    // An offline render owns CoreObject and intentionally keeps the engine stopped;
    // it restarts the engine itself when done. Don't touch it here.
    if (_offlineRenderActive.load(std::memory_order_acquire)) return;

    // An external change (device switch/unplug/format change) STOPS the engine — that's
    // the case we must recover. If the engine is still running, this notification was
    // benign or self-induced by our own record start/stop reconfiguration (which ends
    // with the engine running), so there's nothing to rebuild and no take to abort.
    if (_engine.isRunning) return;

    // If a take was in progress, its input-device context may be gone — finalize the
    // partial recording and hand it back so the UI leaves recording mode and loads it.
    NSURL *interruptedURL = nil;
    if (_isRecording.load(std::memory_order_acquire)) {
        [_engine.inputNode removeTapOnBus:0];
        _isRecording.store(false, std::memory_order_release);
        _recordFile = nil;                       // finalize the partial file on disk
        interruptedURL = _recordURL;
        _recordURL = nil;
    }

    // Rebuild the output graph (connections can be invalidated by the change) and
    // restart. The source node stays at _engineSampleRate; mainMixerNode converts to
    // whatever the new output device wants, so PCM/RNBO state need not change.
    AVAudioFormat *fmt = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:_engineSampleRate channels:2];
    [_engine connect:_sourceNode           to:_engine.mainMixerNode format:fmt];
    [_engine connect:_engine.mainMixerNode  to:_engine.outputNode   format:nil];

    [_engine prepare];
    NSError *err = nil;
    if (![_engine startAndReturnError:&err])
        NSLog(@"[AudioEngine] failed to restart after configuration change: %@", err);

    if (interruptedURL && _recordingInterruptedHandler)
        _recordingInterruptedHandler(interruptedURL);
}

- (void)start {
    _isPlaying.store(true, std::memory_order_relaxed);
}

- (void)stop {
    _isPlaying.store(false, std::memory_order_relaxed);
    // Playhead is intentionally NOT reset — transport position is preserved across stop/start.
}

- (void)stopForOfflineRender {
    // Block the configuration-change handler from restarting the engine while the
    // offline loop owns CoreObject (the engine is intentionally stopped just below).
    _offlineRenderActive.store(true, std::memory_order_release);
    // Suppress parameter-change delivery to Swift for the duration of the offline
    // render. prepareToProcess(reset=true) inside the offline loop fires bang
    // events for the patch's assign_defaults values, and pushAllValuesToEngine
    // (called by the Swift layer immediately after) fires another round through
    // _paramEventInterface. Both are dispatch_async'd to the main queue from
    // within the audio/offline thread; without this flag they would land on
    // the main thread AFTER resumeAfterOfflineRender returns and overwrite the
    // training-computed values in ParameterStore.values.
    _paramCapture.setDeliveryEnabled(false);
    // Suppress spectral message delivery too, so the offline pass doesn't populate
    // the live histogram (Analyze Onsets / Export MIDI are not "playback").
    _messageCapture.setDeliveryEnabled(false);
    [_engine stop];
    // Route MIDI capture to the lossless offline buffer for the render. The engine
    // is now stopped, so no real-time-path (ring) writes race this flip.
    _midiCapture.setOfflineMode(true);
    // Discard any real-time-phase spectral samples still buffered from playback so
    // they don't survive across the offline boundary. Engine is stopped — no producer.
    _messageCapture.resetRing();
}

- (void)resumeAfterOfflineRender {
    // Restore real-time block size. No reset=true — preserves current RNBO parameter
    // state; the Swift layer re-pushes UI values via pushAllValuesToEngine() after this.
    _coreObject.prepareToProcess(_engineSampleRate, kMaxFrames);
    // Route MIDI capture back to the real-time ring BEFORE the engine restarts,
    // so the first resumed render callback is already in real-time mode.
    _midiCapture.setOfflineMode(false);
    // Discard anything the spectral ring accumulated across the offline window (should
    // be empty — delivery was off — but keep the boundary clean) before the engine
    // restarts, so the first resumed real-time samples start fresh.
    _messageCapture.resetRing();
    [_engine prepare];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error])
        NSLog(@"[AudioEngine] failed to restart after offline render: %@", error);
    // Offline render finished — let the configuration-change handler manage the engine again.
    _offlineRenderActive.store(false, std::memory_order_release);
    // Re-enable parameter-change delivery. The Swift layer calls
    // pushAllValuesToEngine() immediately after this — those events come back
    // with source == _paramEventInterface and are filtered out by source id,
    // so the training-computed values that ParameterStore already holds are
    // not displaced.
    _paramCapture.setDeliveryEnabled(true);
    // Re-enable spectral delivery so live playback repopulates the histogram.
    _messageCapture.setDeliveryEnabled(true);
}

// Iterates RNBO's external data refs, loads any file-backed ones from the app
// bundle, and hands the raw interleaved float samples to the CoreObject via
// setExternalData(). Must be called after prepareToProcess().
//
// RNBO's groove~ (Synth Mode 1) reads from buf1/buf2 at DSP time; if these
// data refs are never populated the buffers stay empty and no sample audio
// is produced.
- (void)loadRNBODataRefs {
    RNBO::ExternalDataIndex numRefs = _coreObject.getNumExternalDataRefs();
    for (RNBO::ExternalDataIndex i = 0; i < numRefs; ++i) {
        const RNBO::ExternalDataInfo info = _coreObject.getExternalDataInfo(i);
        if (!info.file || info.file[0] == '\0') continue;  // internal ref — no file to load

        RNBO::ExternalDataId memId = _coreObject.getExternalDataId(i);
        NSString *basename = [[[NSString stringWithUTF8String:info.file] lastPathComponent] copy];
        NSString *stem = [basename stringByDeletingPathExtension];
        NSString *ext  = [basename pathExtension];

        // Search bundle subdirectories in order of most-likely location.
        NSURL *url = [[NSBundle mainBundle] URLForResource:stem withExtension:ext subdirectory:@"RNBO/media"]
                  ?: [[NSBundle mainBundle] URLForResource:stem withExtension:ext subdirectory:@"media"]
                  ?: [[NSBundle mainBundle] URLForResource:stem withExtension:ext];
        if (!url) {
            NSLog(@"[AudioEngine] RNBO data ref '%s': '%@' not found in bundle — "
                  @"ensure the file is added to the target's Copy Bundle Resources phase",
                  memId, basename);
            continue;
        }

        NSError *err = nil;
        AVAudioFile *avFile = [[AVAudioFile alloc] initForReading:url error:&err];
        if (!avFile) {
            NSLog(@"[AudioEngine] RNBO data ref '%s': cannot open '%@': %@", memId, basename, err);
            continue;
        }

        // processingFormat is always Float32 non-interleaved at the file's native rate.
        AVAudioChannelCount numCh  = avFile.processingFormat.channelCount;
        double              fileSR = avFile.processingFormat.sampleRate;
        AVAudioFrameCount   frames = (AVAudioFrameCount)avFile.length;

        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc]
            initWithPCMFormat:avFile.processingFormat frameCapacity:frames];
        if (![avFile readIntoBuffer:pcm error:&err]) {
            NSLog(@"[AudioEngine] RNBO data ref '%s': read error: %@", memId, err);
            continue;
        }
        frames = pcm.frameLength;
        if (frames == 0) {
            NSLog(@"[AudioEngine] RNBO data ref '%s': zero frames in '%@'", memId, basename);
            continue;
        }

        // RNBO's Float32Buffer (InterleavedAudioBuffer<float>) layout:
        //   [ch0f0, ch1f0, ch0f1, ch1f1, ...]
        // For mono this degenerates to a plain sequential array.
        size_t  totalSamples = (size_t)frames * numCh;
        float  *interleaved  = new float[totalSamples];
        float * const *ch    = pcm.floatChannelData;
        for (AVAudioFrameCount f = 0; f < frames; ++f)
            for (AVAudioChannelCount c = 0; c < numCh; ++c)
                interleaved[f * numCh + c] = ch[c][f];

        RNBO::DataType dtype;
        dtype.type = RNBO::DataType::Float32AudioBuffer;
        dtype.audioBufferInfo.channels   = numCh;
        dtype.audioBufferInfo.samplerate = fileSR;

        // The release callback is invoked by RNBO when it no longer needs
        // the buffer (e.g. when new data is set or the CoreObject is torn down).
        _coreObject.setExternalData(
            memId,
            (char *)interleaved,
            totalSamples * sizeof(float),
            dtype,
            [](RNBO::ExternalDataId, char *data) { delete[] (float *)data; }
        );

        NSLog(@"[AudioEngine] RNBO buf '%s' loaded: %u frames, %u ch, %.0f Hz from '%@'",
              memId, (unsigned)frames, (unsigned)numCh, fileSR, basename);
    }
}



- (void)setParameterWithIndex:(int)index value:(float)value {
    // Route through _paramEventInterface (not _coreObject directly) so the
    // resulting parameter event is tagged with this interface's pointer as its
    // source. ParameterEventCapture filters those out to break the feedback
    // loop for user-driven rotary changes to watched parameters.
    _paramEventInterface->setParameterValue(index, value);
}

- (void)setParameterWithId:(NSString *)parameterId value:(float)value {
    RNBO::ParameterIndex idx = _coreObject.getParameterIndexForID(parameterId.UTF8String);
    if (idx == RNBO::INVALID_INDEX) {
        NSLog(@"[AudioEngine] setParameterWithId: unknown parameter '%@'", parameterId);
        return;
    }
    _paramEventInterface->setParameterValue(idx, value);
}

- (int)numParameters {
    return (int)_coreObject.getNumParameters();
}

- (NSDictionary<NSString *, id> *)parameterInfoAtIndex:(int)index {
    RNBO::ParameterInfo info;
    _coreObject.getParameterInfo(index, &info);
    const char *pid = _coreObject.getParameterId(index);
    return @{
        @"id":      [NSString stringWithUTF8String:pid ?: ""],
        @"min":     @((float)info.min),
        @"max":     @((float)info.max),
        @"default": @((float)info.initialValue),
        @"steps":   @(info.steps)
    };
}

- (void)loadAudioFileFromURL:(NSURL *)url {
    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&err];
    if (!file) {
        NSLog(@"[AudioEngine] cannot open file: %@", err);
        return;
    }
    if (file.length == 0) {
        NSLog(@"[AudioEngine] file has zero frames, nothing to load: %@", url.lastPathComponent);
        return;
    }

    double targetSR = _engineSampleRate > 0.0 ? _engineSampleRate : 44100.0;
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:targetSR channels:2];

    // Read the entire file at its native PCM processing format.
    AVAudioPCMBuffer *srcBuf = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:file.processingFormat
        frameCapacity:(AVAudioFrameCount)file.length];
    if (![file readIntoBuffer:srcBuf error:&err]) {
        NSLog(@"[AudioEngine] cannot read file: %@", err);
        return;
    }

    // Convert to stereo float at the engine sample rate when needed
    // (covers mono→stereo upmix, sample rate conversion, or both).
    AVAudioPCMBuffer *dstBuf = srcBuf;
    if (srcBuf.format.sampleRate != targetSR || srcBuf.format.channelCount != 2) {
        AVAudioConverter *conv = [[AVAudioConverter alloc]
            initFromFormat:srcBuf.format toFormat:targetFormat];
        if (!conv) {
            NSLog(@"[AudioEngine] cannot create AVAudioConverter for %@ → %@",
                  srcBuf.format, targetFormat);
            return;
        }
        // +64 provides headroom for converter look-ahead / interpolation latency.
        AVAudioFrameCount cap =
            (AVAudioFrameCount)(srcBuf.frameLength * (targetSR / srcBuf.format.sampleRate)) + 64;
        dstBuf = [[AVAudioPCMBuffer alloc]
            initWithPCMFormat:targetFormat frameCapacity:cap];

        __block BOOL inputConsumed = NO;
        __block AVAudioPCMBuffer *srcRef = srcBuf;
        NSError *convErr = nil;
        [conv convertToBuffer:dstBuf error:&convErr
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount inNumPackets,
                                                AVAudioConverterInputStatus *outStatus) {
                if (!inputConsumed) {
                    inputConsumed = YES;
                    *outStatus = AVAudioConverterInputStatus_HaveData;
                    return srcRef;
                }
                *outStatus = AVAudioConverterInputStatus_EndOfStream;
                return nil;
            }];
        if (convErr) {
            NSLog(@"[AudioEngine] resampling error: %@", convErr);
            return;
        }
    }

    AVAudioFrameCount frameCount = dstBuf.frameLength;
    if (frameCount == 0) {
        NSLog(@"[AudioEngine] file produced zero frames after conversion");
        return;
    }

    float * const *data = dstBuf.floatChannelData;
    float *newL = new float[frameCount];
    float *newR = new float[frameCount];
    memcpy(newL, data[0], frameCount * sizeof(float));
    memcpy(newR, data[1], frameCount * sizeof(float));

    // Atomically swap in the new buffers and reset the playhead for the new file.
    float *oldL = _pcmL.exchange(newL, std::memory_order_acq_rel);
    float *oldR = _pcmR.exchange(newR, std::memory_order_acq_rel);
    _pcmFrameCount.store((int64_t)frameCount, std::memory_order_release);
    _playhead.store(0, std::memory_order_relaxed);

    // Defer freeing old buffers — the render thread may still be mid-read.
    if (oldL || oldR) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            delete[] oldL;
            delete[] oldR;
        });
    }

    NSLog(@"[AudioEngine] loaded %u frames at %.0f Hz from %@",
          (unsigned)frameCount, targetSR, url.lastPathComponent);
}

- (void)rewindToStart {
    _playhead.store(0, std::memory_order_relaxed);
}

- (void)setPlayheadPosition:(int64_t)frame {
    int64_t total = _pcmFrameCount.load(std::memory_order_relaxed);
    int64_t clamped = frame < 0 ? 0 : (frame > total ? total : frame);
    _playhead.store(clamped, std::memory_order_relaxed);
    // Arm a post-seek MIDI settling window: RNBO's ~kRnboProcessingLatencyMs
    // detection latency means an onset from pre-seek audio can be emitted a few blocks
    // after the seek and stamped at the new playhead; the settling window drops those
    // (and the seek discontinuity's false-triggers) so they aren't drawn.
    _midiCapture.armSeekSettle();
}

// ---------------------------------------------------------------------------
// Live input recording (Step 9 — Workflow 2b, no monitoring)
//
// Branch A only: a tap on the input node writes each incoming buffer straight to
// disk and folds its envelope into the live 60 s waveform. RNBO is fed silence
// (transport forced to its stopped state) so nothing is monitored — the always-
// alive render block keeps calling process() so any prior effects tail rings out.
// There is deliberately no ring buffer here; that (and monitoring) is Step 9.5.
// ---------------------------------------------------------------------------

- (void)startRecordingToURL:(NSURL *)url {
    if (_isRecording.load(std::memory_order_acquire)) return;

    // Query the input format while the engine is still running (reliable here); the
    // tap delivers buffers in this format.
    AVAudioFormat *inputFmt = [_engine.inputNode outputFormatForBus:0];
    if (inputFmt.sampleRate <= 0.0 || inputFmt.channelCount == 0) {
        NSLog(@"[AudioEngine] cannot record: invalid input format %@", inputFmt);
        return;
    }

    NSError *err = nil;
    _recordFile = [[AVAudioFile alloc] initForWriting:url
                                             settings:inputFmt.settings
                                                error:&err];
    if (!_recordFile) {
        NSLog(@"[AudioEngine] cannot open recording file: %@", err);
        return;
    }
    _recordURL = url;
    _recordedFrames.store(0, std::memory_order_relaxed);
    _liveWaveform.reset(inputFmt.sampleRate);

    // Adding an input tap changes the engine's shared input/output I/O unit
    // configuration. On macOS this MUST be done while the engine is stopped —
    // installing the tap on the running (output-only) engine yields no input data,
    // throws -10877 (kAudioUnitErr_InvalidElement), and corrupts output so later
    // playback fails too. So: stop → install tap → restart with input+output active.
    // (This briefly interrupts any ringing effects tail — see -stopRecording.)
    [_engine stop];

    // Feed RNBO silence during the take (no monitoring of the live input).
    _isPlaying.store(false, std::memory_order_relaxed);

    // Weak self so the tap block doesn't retain the engine (self → _engine → tap
    // block → self cycle). The tap runs off the real-time render thread, so the ARC
    // load and file I/O here are acceptable (this is the documented recording pattern,
    // unlike the strictly real-time source-node render block — Branch A needs no ring).
    // Reading _recordFile per-call rather than capturing it strongly lets -stopRecording
    // drop the last reference and finalize the file on disk before the handoff load reads it.
    __weak AudioEngine *weakSelf = self;
    [_engine.inputNode installTapOnBus:0
                            bufferSize:4096
                                format:inputFmt
                                 block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong AudioEngine *s = weakSelf;
        if (!s) return;

        NSError *werr = nil;
        if (![s->_recordFile writeFromBuffer:buffer error:&werr])
            NSLog(@"[AudioEngine] recording write error: %@", werr);

        AVAudioFrameCount    n     = buffer.frameLength;
        int64_t              start = s->_recordedFrames.load(std::memory_order_relaxed);
        const float * const *ch    = buffer.floatChannelData;
        if (ch && ch[0]) s->_liveWaveform.addSamples(ch[0], (int64_t)n, start);
        s->_recordedFrames.store(start + (int64_t)n, std::memory_order_relaxed);
    }];

    [_engine prepare];
    NSError *startErr = nil;
    if (![_engine startAndReturnError:&startErr]) {
        // Most likely the default input and output are different devices (macOS
        // requires one shared device for AVAudioEngine I/O). Abort the take and
        // recover output-only playback so the app isn't left silent.
        NSLog(@"[AudioEngine] failed to start engine for recording: %@", startErr);
        [_engine.inputNode removeTapOnBus:0];
        _recordFile = nil;
        if (_recordURL) [[NSFileManager defaultManager] removeItemAtURL:_recordURL error:nil];
        _recordURL  = nil;
        [_engine prepare];
        NSError *recoverErr = nil;
        if (![_engine startAndReturnError:&recoverErr])
            NSLog(@"[AudioEngine] failed to recover engine after record-start failure: %@", recoverErr);
        return;
    }

    _isRecording.store(true, std::memory_order_release);
    NSLog(@"[AudioEngine] recording started: %.0f Hz, %u ch → %@",
          inputFmt.sampleRate, (unsigned)inputFmt.channelCount, url.lastPathComponent);
}

- (nullable NSURL *)stopRecording {
    if (!_isRecording.load(std::memory_order_acquire)) return nil;

    // Removing the tap also reconfigures the I/O unit, so do it while stopped, then
    // resume output-only rendering. RNBO/DSP parameter state survives the restart
    // (no prepareToProcess reset here).
    [_engine stop];
    [_engine.inputNode removeTapOnBus:0];
    _isRecording.store(false, std::memory_order_release);

    // Dropping the last strong reference finalizes the file header on disk.
    _recordFile = nil;

    [_engine prepare];
    NSError *e = nil;
    if (![_engine startAndReturnError:&e])
        NSLog(@"[AudioEngine] failed to restart engine after recording: %@", e);

    NSURL *url = _recordURL;
    _recordURL = nil;
    NSLog(@"[AudioEngine] recording stopped: %.2f s to %@",
          (double)_recordedFrames.load(std::memory_order_relaxed) / _liveWaveform.sampleRate,
          url.lastPathComponent);
    return url;
}

- (BOOL)isRecording {
    return _isRecording.load(std::memory_order_acquire);
}

- (double)recordingElapsedMs {
    double sr = _liveWaveform.sampleRate;
    if (sr <= 0.0) return 0.0;
    return (double)_recordedFrames.load(std::memory_order_relaxed) / sr * 1000.0;
}

- (nullable NSData *)recordingWaveformBins {
    NSMutableData *data =
        [NSMutableData dataWithLength:(NSUInteger)(LiveWaveform::kBinCount * 2 * sizeof(float))];
    _liveWaveform.copyBins((float *)data.mutableBytes);
    return [data copy];
}

- (void)beginRealTimeCapture {
    // Discard any real-time events still buffered from the previous transport
    // session so a fresh timeline (play start / seek) starts clean. Timestamps are
    // now stamped per-block on the audio thread, so there is no anchor
    // to set here — a seek can no longer retroactively re-time surviving events.
    _midiCapture.resetRealTimeRing();
}

- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearRealTimeMidiEvents {
    // Timestamps were converted to file-relative ms on the audio thread when each
    // event was produced — including the transport-loop fmod wrap — so
    // there is no anchor math here; read fileMs straight through.
    std::vector<RtMidiEvent> events = _midiCapture.drainRealTimeRing();
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:events.size()];
    for (const RtMidiEvent &ev : events) {
        NSData *bytes = [NSData dataWithBytes:ev.bytes length:(NSUInteger)ev.len];
        [result addObject:@{
            @"timestampMs": @(ev.fileMs),
            @"bytes":       bytes
        }];
    }
    return [result copy];
}

- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearSpectralEvents {
    // Drain the lock-free spectral ring on the main thread and box each POD sample
    // into a dictionary here (never on the audio thread). "feature" is
    // 0 = SpectralCentroid, 1 = SpectralFlatness (matches SpectralFeature).
    std::vector<SpectralMsg> msgs = _messageCapture.drainRing();
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:msgs.size()];
    for (const SpectralMsg &m : msgs) {
        [result addObject:@{
            @"feature": @(m.feature),
            @"value":   @(m.value)
        }];
    }
    return [result copy];
}

- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearMidiEvents {
    std::vector<RNBO::MidiEvent> events = _midiCapture.collectAndClear();
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:events.size()];
    for (const RNBO::MidiEvent &ev : events) {
        NSData *bytes = [NSData dataWithBytes:ev.getData() length:(NSUInteger)ev.getLength()];
        // Normalise to file-relative time: RNBO's time counter is cumulative and
        // not reset by prepareToProcess, so subtract the offset captured at the
        // start of the most recent offline render main loop.
        double ms = ev.getTime() - _offlineRenderStartMs;
        [result addObject:@{
            @"timestampMs": @(ms),
            @"bytes":       bytes
        }];
    }
    return [result copy];
}

// ---------------------------------------------------------------------------
// Private offline processing loop shared by -renderOfflineAudioToURL:error:
// and -renderOfflineMIDI. Resets RNBO DSP state, then drives process() over
// the entire loaded PCM array in kOfflineBlockSize-frame blocks.
//
// `audioFile` may be nil (MIDI-only pass); when non-nil, each block's output
// is written to the file. `pcmBuf` must be pre-allocated with capacity
// kOfflineBlockSize when `audioFile` is non-nil; ignored when nil.
//
// Returns NO and populates *outError if an AVAudioFile write fails.
// ---------------------------------------------------------------------------
- (BOOL)_runOfflineLoopWritingTo:(AVAudioFile *)audioFile
                          pcmBuf:(AVAudioPCMBuffer *)pcmBuf
                           error:(NSError **)outError {
    float   *pcmL      = _pcmL.load(std::memory_order_acquire);
    float   *pcmR      = _pcmR.load(std::memory_order_acquire);
    int64_t  total     = _pcmFrameCount.load(std::memory_order_acquire);

    _coreObject.prepareToProcess(_engineSampleRate, kOfflineBlockSize, true);
    _midiCapture.collectAndClear(); // clear offline buffer (defensive; empty in normal flow)

    std::vector<RNBO::SampleValue> inL(kOfflineBlockSize, 0.0);
    std::vector<RNBO::SampleValue> inR(kOfflineBlockSize, 0.0);
    std::vector<RNBO::SampleValue> outL(kOfflineBlockSize, 0.0);
    std::vector<RNBO::SampleValue> outR(kOfflineBlockSize, 0.0);

    RNBO::SampleValue *inBufs[2]  = { inL.data(), inR.data() };
    RNBO::SampleValue *outBufs[2] = { outL.data(), outR.data() };

    // Drain RNBO's startup ParameterBangEvents (scheduled at t=0 during CoreObject
    // construction) so they don't clobber the UI parameter values pushed by the Swift
    // layer (ParameterStore.pushAllValuesToEngine) before this method was called.
    // Those queued values also fire here — after the bang events — so they persist
    // into the main render loop. Without this block the bang events win and the patch
    // runs with assign_defaults values whenever no prior real-time blocks have run.
    _coreObject.process(inBufs, 2, outBufs, 2, kOfflineBlockSize);
    _midiCapture.drain();
    _paramCapture.drain();
    _messageCapture.drain(); // delivery disabled during offline — drops events, keeps queue empty
    _midiCapture.collectAndClear(); // discard pre-warm events

    // Record absolute RNBO engine time at the start of the main render loop.
    // RNBO's time counter is cumulative (not reset by prepareToProcess), so
    // collectAndClearMidiEvents subtracts this offset to produce file-relative ms.
    _offlineRenderStartMs = _coreObject.getCurrentTime();

    int64_t pos = 0;
    while (pos < total) {
        AVAudioFrameCount frames =
            (AVAudioFrameCount)std::min((int64_t)kOfflineBlockSize, total - pos);

        // Copy valid input samples; remainder of the block stays zero-padded.
        for (AVAudioFrameCount i = 0; i < frames; ++i) {
            inL[i] = (RNBO::SampleValue)pcmL[pos + i];
            inR[i] = (RNBO::SampleValue)pcmR[pos + i];
        }
        // Zero any leftover tail (last block may be smaller than kOfflineBlockSize).
        for (AVAudioFrameCount i = frames; i < kOfflineBlockSize; ++i) {
            inL[i] = 0.0; inR[i] = 0.0;
        }

        _coreObject.process(inBufs, 2, outBufs, 2, kOfflineBlockSize);
        _midiCapture.drain();
        _paramCapture.drain();
        _messageCapture.drain(); // delivery disabled during offline — drops events, keeps queue empty

        if (audioFile) {
            float * const *ch = pcmBuf.floatChannelData;
            for (AVAudioFrameCount i = 0; i < frames; ++i) {
                ch[0][i] = (float)outL[i];
                ch[1][i] = (float)outR[i];
            }
            pcmBuf.frameLength = frames;
            if (![audioFile writeFromBuffer:pcmBuf error:outError])
                return NO;
        }

        pos += frames;
    }
    return YES;
}

- (BOOL)renderOfflineAudioToURL:(NSURL *)url error:(NSError **)outError {
    float   *pcmL  = _pcmL.load(std::memory_order_acquire);
    int64_t  total = _pcmFrameCount.load(std::memory_order_acquire);
    if (!pcmL || total == 0) {
        if (outError)
            *outError = [NSError errorWithDomain:@"AudioEngine" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"No audio file loaded."}];
        return NO;
    }

    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:_engineSampleRate channels:2];
    AVAudioFile *outFile = [[AVAudioFile alloc]
        initForWriting:url settings:format.settings error:outError];
    if (!outFile) return NO;

    AVAudioPCMBuffer *pcmBuf = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:format frameCapacity:kOfflineBlockSize];

    BOOL ok = [self _runOfflineLoopWritingTo:outFile pcmBuf:pcmBuf error:outError];

    NSLog(@"[AudioEngine] offline audio render %@: %.1f s to %@",
          ok ? @"complete" : @"failed",
          (double)total / _engineSampleRate,
          url.lastPathComponent);
    return ok;
}

- (void)renderOfflineMIDI {
    float   *pcmL  = _pcmL.load(std::memory_order_acquire);
    int64_t  total = _pcmFrameCount.load(std::memory_order_acquire);
    if (!pcmL || total == 0) {
        NSLog(@"[AudioEngine] renderOfflineMIDI: no audio loaded");
        return;
    }

    [self _runOfflineLoopWritingTo:nil pcmBuf:nil error:nil];

    NSLog(@"[AudioEngine] offline MIDI render complete: %.1f s processed",
          (double)total / _engineSampleRate);
}

- (NSData *)waveformThumbnailDataWithBinCount:(NSInteger)binCount {
    float   *pcmL  = _pcmL.load(std::memory_order_acquire);
    int64_t  total = _pcmFrameCount.load(std::memory_order_acquire);
    if (!pcmL || total == 0 || binCount <= 0) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(binCount * 2 * sizeof(float))];
    float *out = (float *)data.mutableBytes;

    for (NSInteger i = 0; i < binCount; ++i) {
        int64_t start = i * total / binCount;
        int64_t end   = (i + 1) * total / binCount;
        if (end > total) end = total;
        if (start >= end) {
            out[i * 2]     = 0.0f;
            out[i * 2 + 1] = 0.0f;
            continue;
        }
        float mn = pcmL[start], mx = pcmL[start];
        for (int64_t f = start + 1; f < end; ++f) {
            float s = pcmL[f];
            if (s < mn) mn = s;
            if (s > mx) mx = s;
        }
        out[i * 2]     = mn;
        out[i * 2 + 1] = mx;
    }
    return [data copy];
}

- (double)playheadFraction {
    int64_t total = _pcmFrameCount.load(std::memory_order_relaxed);
    if (total == 0) return 0.0;
    return (double)_playhead.load(std::memory_order_relaxed) / (double)total;
}

- (int64_t)totalFrameCount {
    return _pcmFrameCount.load(std::memory_order_relaxed);
}

- (double)sampleRate {
    return _engineSampleRate;
}

- (double)processingLatencyMs {
    return kRnboProcessingLatencyMs;
}

@end
