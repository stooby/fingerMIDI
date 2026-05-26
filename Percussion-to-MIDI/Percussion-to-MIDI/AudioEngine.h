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
@end
#endif

#endif /* AudioEngine_h */
