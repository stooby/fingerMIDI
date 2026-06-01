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
- (void)start;
- (void)stop;
- (void)setParameterWithIndex:(int)index value:(float)value NS_SWIFT_NAME(setParameter(index:value:));
- (void)setParameterWithId:(NSString *)parameterId value:(float)value NS_SWIFT_NAME(setParameter(id:value:));
- (int)numParameters;
- (NSDictionary<NSString *, id> *)parameterInfoAtIndex:(int)index NS_SWIFT_NAME(parameterInfo(at:));
- (void)loadAudioFileFromURL:(NSURL *)url;
- (void)rewindToStart;
- (void)setPlayheadPosition:(int64_t)frame;

/// Returns all MIDI events accumulated since the last call (or since the last reset) and clears
/// the buffer. Each element is an NSDictionary with keys:
///   "timestampMs" → NSNumber (double) — RNBO engine time in milliseconds
///   "bytes"       → NSData           — raw MIDI bytes (1–3 bytes per event)
- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearMidiEvents
    NS_SWIFT_NAME(collectAndClearMidiEvents());

/// Offline audio export. Runs the full loaded PCM array through RNBO in a tight loop (no audio
/// device) and writes the processed output to an audio file at `url`. Blocking — call from a
/// background thread. Engine must be stopped before calling.
/// Returns YES on success, NO on failure (error written to `outError`).
- (BOOL)renderOfflineAudioToURL:(NSURL *)url
                          error:(NSError **)outError
    NS_SWIFT_NAME(renderOfflineAudio(to:));

/// Offline MIDI export. Runs the full loaded PCM array through RNBO in a tight loop (no audio
/// device), accumulating all MIDI events emitted by the patch. Blocking — call from a background
/// thread. Engine must be stopped before calling.
/// After this returns, retrieve the accumulated events via -collectAndClearMidiEvents.
- (void)renderOfflineMIDI NS_SWIFT_NAME(renderOfflineMIDI());
@end
#endif

#endif /* AudioEngine_h */
