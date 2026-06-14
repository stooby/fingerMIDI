//
//  AudioEngine.mm
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/23/26.
//

#import "AudioEngine.h"
#import <AVFoundation/AVFoundation.h>
#include "rnbo/RNBO.h"
#include "rnbo_snare-kick-detector.cpp"   // generated RNBO patch file
#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>

// ---------------------------------------------------------------------------
// MIDI event accumulator
//
// Subclasses RNBO::EventHandler to capture outgoing MidiEvents from the RNBO
// patch. Design notes:
//
//  • eventsAvailable() is a no-op — we call drain() explicitly after each
//    process() call so the architecture doc's "drain after every process block"
//    contract is honoured for both real-time and offline loops.
//
//  • handleMidiEvent() is called from drain(), which runs on whatever thread
//    calls drain() (the audio render thread during real-time playback, or the
//    offline-render thread). collectAndClear() is called from the Swift/main
//    thread. The mutex guards the shared _events vector against this race.
//    Contention is negligible: MIDI events from a percussion detector are
//    sparse (one per hit), so the mutex is almost never contested.
//
//  • drain() is a thin public wrapper around EventHandler::drainEvents()
//    (which is protected), used by both the render block and the offline loop.
// ---------------------------------------------------------------------------
class MidiEventCapture : public RNBO::EventHandler {
public:
    // Called from within process() on the audio thread — intentionally a no-op.
    // We drain explicitly after process() instead.
    void eventsAvailable() override {}

    void handleMidiEvent(const RNBO::MidiEvent& event) override {
        std::lock_guard<std::mutex> lock(_mutex);
        _events.push_back(event);
    }

    // Public wrapper for the protected drainEvents(); call after each process().
    void drain() { drainEvents(); }

    // Returns all accumulated events and clears the buffer.
    std::vector<RNBO::MidiEvent> collectAndClear() {
        std::lock_guard<std::mutex> lock(_mutex);
        std::vector<RNBO::MidiEvent> out;
        out.swap(_events);
        return out;
    }

private:
    std::mutex _mutex;
    std::vector<RNBO::MidiEvent> _events;
};

// Safe upper bound for any macOS hardware buffer size; passed to
// prepareToProcess() so RNBO pre-allocates its internal working memory.
static const AVAudioFrameCount kMaxFrames = 4096;

// Block size used for offline rendering. Smaller than the real-time buffer to
// maximise timestamp resolution for onset detection (≈1.45 ms at 44.1 kHz).
static const AVAudioFrameCount kOfflineBlockSize = 64;

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

    // MIDI event capture. _midiCapture must outlive _paramEventInterface
    // (the interface holds a raw pointer to the handler); see -dealloc.
    MidiEventCapture                       _midiCapture;
    RNBO::ParameterEventInterfaceUniquePtr _paramEventInterface;

    // Absolute RNBO engine time (ms) at the start of the most recent offline
    // render main loop. RNBO's time counter is cumulative and is not reset by
    // prepareToProcess, so event timestamps must be normalised by subtracting
    // this offset to produce file-relative times.
    RNBO::MillisecondTime _offlineRenderStartMs;

    // Real-time playback timestamp anchor. Set by -beginRealTimeCapture (main thread)
    // and consumed by the render block (audio thread) on the next process() call.
    // _rtAnchorPlayheadFrame is written by the main thread before _needsRtAnchor is set,
    // so the audio thread sees a consistent value once it observes _needsRtAnchor == true.
    // _rtAnchorRnboTime is written by the audio thread and read by the main thread;
    // stored as uint64_t bit-pattern to allow std::atomic usage with a double.
    std::atomic<bool>     _needsRtAnchor;
    std::atomic<int64_t>  _rtAnchorPlayheadFrame;
    std::atomic<uint64_t> _rtAnchorRnboTimeBits; // IEEE 754 double stored as uint64_t
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Wire the MIDI event handler to CoreObject. SingleProducer gives us a
        // lock-free queue between the audio thread (producer) and our drain()
        // calls (consumer). The returned interface must be kept alive as long as
        // we want events; it is reset in -dealloc before _midiCapture is destroyed.
        _paramEventInterface = _coreObject.createParameterInterface(
            RNBO::ParameterEventInterface::SingleProducer,
            &_midiCapture
        );
        [self setupEngine];
    }
    return self;
}

- (void)dealloc {
    [_engine stop];
    // Reset the interface before _midiCapture is destroyed (it holds a raw pointer).
    _paramEventInterface.reset();
    delete[] _inL;
    delete[] _inR;
    delete[] _outL;
    delete[] _outR;
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
    RNBO::SampleValue    *inL            = _inL;
    RNBO::SampleValue    *inR            = _inR;
    RNBO::SampleValue    *outL           = _outL;
    RNBO::SampleValue    *outR           = _outR;
    std::atomic<float *> *pcmLPtr        = &_pcmL;
    std::atomic<float *> *pcmRPtr        = &_pcmR;
    std::atomic<int64_t> *framesPtr      = &_pcmFrameCount;
    std::atomic<int64_t> *headPtr        = &_playhead;
    std::atomic<bool>    *isPlayingPtr        = &_isPlaying;
    std::atomic<bool>    *needsRtAnchorPtr   = &_needsRtAnchor;
    std::atomic<uint64_t>*rtAnchorBitsPtr    = &_rtAnchorRnboTimeBits;

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

            // Capture real-time anchor: record RNBO engine time at the playhead frame
            // stored by beginRealTimeCapture(). Must happen before process() advances time.
            if (needsRtAnchorPtr->load(std::memory_order_acquire) && playing) {
                RNBO::MillisecondTime t = core->getCurrentTime();
                uint64_t bits;
                memcpy(&bits, &t, sizeof(bits));
                rtAnchorBitsPtr->store(bits, std::memory_order_release);
                needsRtAnchorPtr->store(false, std::memory_order_release);
            }

            if (playing && pcmL != nullptr && total > 0) {
                // Guard against pos landing at or past total (e.g. from an
                // external setPlayheadPosition call right at the file boundary).
                if (pos >= total) pos = pos % total;

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
}

- (void)start {
    _isPlaying.store(true, std::memory_order_relaxed);
}

- (void)stop {
    _isPlaying.store(false, std::memory_order_relaxed);
    // Playhead is intentionally NOT reset — transport position is preserved across stop/start.
}

- (void)stopForOfflineRender {
    [_engine stop];
}

- (void)resumeAfterOfflineRender {
    // Restore real-time block size. No reset=true — preserves current RNBO parameter
    // state; the Swift layer re-pushes UI values via pushAllValuesToEngine() after this.
    _coreObject.prepareToProcess(_engineSampleRate, kMaxFrames);
    [_engine prepare];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error])
        NSLog(@"[AudioEngine] failed to restart after offline render: %@", error);
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
    _coreObject.setParameterValue(index, value);
}

- (void)setParameterWithId:(NSString *)parameterId value:(float)value {
    RNBO::ParameterIndex idx = _coreObject.getParameterIndexForID(parameterId.UTF8String);
    if (idx == RNBO::INVALID_INDEX) {
        NSLog(@"[AudioEngine] setParameterWithId: unknown parameter '%@'", parameterId);
        return;
    }
    _coreObject.setParameterValue(idx, value);
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
}

- (void)beginRealTimeCapture {
    // Snapshot the playhead frame first so the audio thread sees a stable anchor
    // value once it observes _needsRtAnchor == true.
    _rtAnchorPlayheadFrame.store(_playhead.load(std::memory_order_relaxed),
                                 std::memory_order_relaxed);
    _needsRtAnchor.store(true, std::memory_order_release);
}

- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearRealTimeMidiEvents {
    // Read the anchor values. _rtAnchorRnboTimeBits is written by the audio thread
    // (after _needsRtAnchor clears) and read here on the main thread.
    uint64_t bits = _rtAnchorRnboTimeBits.load(std::memory_order_acquire);
    RNBO::MillisecondTime anchorRnboMs;
    memcpy(&anchorRnboMs, &bits, sizeof(anchorRnboMs));
    double anchorFileMs = (double)_rtAnchorPlayheadFrame.load(std::memory_order_relaxed)
                          / _engineSampleRate * 1000.0;
    // Total file duration in ms — used to wrap timestamps back into [0, totalMs) after
    // loop iterations. RNBO time advances monotonically regardless of transport looping,
    // so without fmod every post-wrap event maps past the right edge of the waveform.
    double totalMs = (double)_pcmFrameCount.load(std::memory_order_relaxed)
                     / _engineSampleRate * 1000.0;

    std::vector<RNBO::MidiEvent> events = _midiCapture.collectAndClear();
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:events.size()];
    for (const RNBO::MidiEvent &ev : events) {
        NSData *bytes = [NSData dataWithBytes:ev.getData() length:(NSUInteger)ev.getLength()];
        double ms = anchorFileMs + (ev.getTime() - anchorRnboMs);
        if (totalMs > 0) ms = fmod(ms, totalMs);
        [result addObject:@{
            @"timestampMs": @(ms),
            @"bytes":       bytes
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
    _midiCapture.collectAndClear(); // discard any real-time-phase events

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

@end
