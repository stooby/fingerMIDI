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

// TODO (Step 7): after startAndReturnError:, read engine.outputNode's actual
// sampleRate and maxFrames, re-call prepareToProcess with those values, then
// use them to decide whether imported audio needs AVAudioConverter resampling.
static const double            kSampleRate = 44100.0;
static const AVAudioFrameCount kMaxFrames  = 512;

@implementation AudioEngine {
    RNBO::CoreObject   _coreObject;
    AVAudioEngine     *_engine;
    AVAudioSourceNode *_sourceNode;
    RNBO::SampleValue *_inL;
    RNBO::SampleValue *_inR;
    RNBO::SampleValue *_outL;
    RNBO::SampleValue *_outR;
}

- (void)start {
    _engine = [[AVAudioEngine alloc] init];

    _inL  = new RNBO::SampleValue[kMaxFrames]();  // zero-filled silence
    _inR  = new RNBO::SampleValue[kMaxFrames]();
    _outL = new RNBO::SampleValue[kMaxFrames]();
    _outR = new RNBO::SampleValue[kMaxFrames]();

    _coreObject.prepareToProcess(kSampleRate, kMaxFrames);

    // Capture raw pointers — no ObjC message sends on the audio thread.
    RNBO::CoreObject *core = &_coreObject;
    RNBO::SampleValue *inL  = _inL;
    RNBO::SampleValue *inR  = _inR;
    RNBO::SampleValue *outL = _outL;
    RNBO::SampleValue *outR = _outR;

    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:kSampleRate channels:2];

    _sourceNode = [[AVAudioSourceNode alloc]
        initWithFormat:format
        renderBlock:^OSStatus(BOOL *isSilence,
                              const AudioTimeStamp *timestamp,
                              AVAudioFrameCount frameCount,
                              AudioBufferList *outputData) {

            // TODO (Step 7): replace inL/inR with PCM data from the imported
            // audio file, streamed via a playhead-indexed host buffer.
            RNBO::SampleValue *inBufs[2]  = { inL, inR };   // zeroed silence
            RNBO::SampleValue *outBufs[2] = { outL, outR };
            core->process(inBufs, 2, outBufs, 2, frameCount);

            // Convert RNBO SampleValue output → Core Audio float buffers.
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
    [_engine connect:_sourceNode        to:_engine.mainMixerNode format:format];
    [_engine connect:_engine.mainMixerNode to:_engine.outputNode  format:nil];

    NSError *error = nil;
    
    if (![_engine startAndReturnError:&error])
        NSLog(@"[AudioEngine] failed to start: %@", error);
}

- (void)stop {
    [_engine stop];
    _sourceNode = nil;
    _engine     = nil;
    delete[] _inL;  _inL  = nullptr;
    delete[] _inR;  _inR  = nullptr;
    delete[] _outL; _outL = nullptr;
    delete[] _outR; _outR = nullptr;
}

- (void)setParameterWithIndex:(int)index value:(float)value {
    _coreObject.setParameterValue(index, value);
}

@end
