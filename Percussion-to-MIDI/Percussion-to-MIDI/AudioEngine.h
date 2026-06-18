//
//  AudioEngine.h
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/23/26.
//

#ifndef AudioEngine_h
#define AudioEngine_h

#ifdef __OBJC__
#import <Foundation/Foundation.h>

@interface AudioEngine : NSObject

/// Starts audio file playback. The AVAudioEngine and RNBO DSP continue running
/// regardless — this only gates whether PCM data is fed to RNBO.
- (void)start;

/// Stops audio file playback. The AVAudioEngine and RNBO DSP keep running so
/// that effects tails (delay, reverb, etc.) ring out naturally.
- (void)stop;

/// Stops the AVAudioEngine hardware IO in preparation for an offline render.
/// Call on the main thread before renderOfflineAudio(to:) or renderOfflineMIDI().
/// Always pair with a subsequent call to resumeAfterOfflineRender().
- (void)stopForOfflineRender NS_SWIFT_NAME(stopForOfflineRender());

/// Restores the AVAudioEngine hardware IO and re-prepares RNBO for real-time
/// processing after an offline render. Call on the main thread, then call
/// pushAllValuesToEngine() via ParameterStore to restore parameter state.
- (void)resumeAfterOfflineRender NS_SWIFT_NAME(resumeAfterOfflineRender());

- (void)setParameterWithIndex:(int)index value:(float)value NS_SWIFT_NAME(setParameter(index:value:));
- (void)setParameterWithId:(NSString *)parameterId value:(float)value NS_SWIFT_NAME(setParameter(id:value:));
- (int)numParameters;
- (NSDictionary<NSString *, id> *)parameterInfoAtIndex:(int)index NS_SWIFT_NAME(parameterInfo(at:));
- (void)loadAudioFileFromURL:(NSURL *)url;
- (void)rewindToStart;
- (void)setPlayheadPosition:(int64_t)frame;

/// Downsamples the left-channel PCM into `binCount` min/max pairs, returned
/// as a flat NSData of Float32 values: [min₀, max₀, min₁, max₁, ...].
/// Returns nil if no audio is loaded. O(N) in total PCM frame count.
/// Call on a background thread immediately after loadAudioFileFromURL:.
- (nullable NSData *)waveformThumbnailDataWithBinCount:(NSInteger)binCount
    NS_SWIFT_NAME(waveformThumbnailData(binCount:));

/// Current playhead position as a fraction in [0, 1] of total file length.
/// Atomic load — safe to read from the main thread at 30 fps.
@property (readonly) double playheadFraction;

/// Total loaded PCM frame count. Returns 0 if no audio is loaded.
@property (readonly) int64_t totalFrameCount;

/// Hardware sample rate in Hz. Used by the Swift layer to convert frame counts to milliseconds.
@property (readonly) double sampleRate;

/// Returns all MIDI events accumulated since the last call (or since the last reset) and clears
/// the buffer. Each element is an NSDictionary with keys:
///   "timestampMs" → NSNumber (double) — RNBO engine time in milliseconds
///   "bytes"       → NSData           — raw MIDI bytes (1–3 bytes per event)
- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearMidiEvents
    NS_SWIFT_NAME(collectAndClearMidiEvents());

/// Call on the main thread immediately before start() (and after setPlayheadPosition()
/// when seeking during playback) to initialise the timestamp anchor used by
/// collectAndClearRealTimeMidiEvents(). Records the current playhead frame and sets
/// a flag for the render block to capture the matching RNBO engine time on the next
/// process() call.
- (void)beginRealTimeCapture NS_SWIFT_NAME(beginRealTimeCapture());

/// Returns all MIDI events accumulated during real-time playback since the last call,
/// with timestamps converted to file-relative milliseconds via the anchor set by
/// beginRealTimeCapture(). Same dictionary format as collectAndClearMidiEvents().
/// Safe to call from the main thread.
- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearRealTimeMidiEvents
    NS_SWIFT_NAME(collectAndClearRealTimeMidiEvents());

/// Offline audio export. Runs the full loaded PCM array through RNBO in a tight loop (no audio
/// device) and writes the processed output to an audio file at `url`. Blocking — call from a
/// background thread. Call stopForOfflineRender() on the main thread before dispatching.
/// Returns YES on success, NO on failure (error written to `outError`).
- (BOOL)renderOfflineAudioToURL:(NSURL *)url
                          error:(NSError **)outError
    NS_SWIFT_NAME(renderOfflineAudio(to:));

/// Offline MIDI export. Runs the full loaded PCM array through RNBO in a tight loop (no audio
/// device), accumulating all MIDI events emitted by the patch. Blocking — call from a background
/// thread. Call stopForOfflineRender() on the main thread before dispatching.
/// After this returns, retrieve the accumulated events via -collectAndClearMidiEvents.
- (void)renderOfflineMIDI NS_SWIFT_NAME(renderOfflineMIDI());

/// Callback invoked on the main thread whenever the RNBO patch internally writes a
/// new value to a watched parameter (currently SpecFlatCutoff and SpecCentCutoff,
/// which the patch sets after EnableTraining runs). Self-writes from
/// -setParameterWithIndex:value: / -setParameterWithId:value: are filtered out at
/// the source-id level and never reach this block. `index` is the RNBO parameter
/// index; `value` is the new value.
@property (nonatomic, copy, nullable) void (^parameterChangeHandler)(int index, float value);
@end
#endif

#endif /* AudioEngine_h */
