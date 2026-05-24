//
//  AudioEngine.mm
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/23/26.
//

#import "AudioEngine.h"
#include "rnbo/RNBO.h"
#include "rnbo_snare-kick-detector.cpp"   // generated RNBO patch file

@implementation AudioEngine {
    RNBO::CoreObject _coreObject;
}
@end
