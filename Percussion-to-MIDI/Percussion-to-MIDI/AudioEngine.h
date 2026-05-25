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
- (void)setParameterWithIndex:(int)index value:(float)value;
- (void)loadAudioFileFromURL:(NSURL *)url;
- (void)rewindToStart;
- (void)setPlayheadPosition:(int64_t)frame;
@end
#endif

#endif /* AudioEngine_h */
