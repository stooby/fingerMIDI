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

// Safe upper bound for any macOS hardware buffer size; passed to
// prepareToProcess() so RNBO pre-allocates its internal working memory.
static const AVAudioFrameCount kMaxFrames = 4096;

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

    // Cached hardware sample rate — queried at init so file import can resample
    // correctly even before -start is called.
    double _engineSampleRate;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        AVAudioEngine *tmp = [[AVAudioEngine alloc] init];
        double sr = [tmp.outputNode outputFormatForBus:0].sampleRate;
        _engineSampleRate = sr > 0.0 ? sr : 44100.0;
    }
    return self;
}

- (void)start {
    _engine = [[AVAudioEngine alloc] init];

    // Confirm the hardware rate; update if the default output device changed.
    double realSR = [_engine.outputNode outputFormatForBus:0].sampleRate;
    if (realSR <= 0.0) realSR = _engineSampleRate;
    _engineSampleRate = realSR;

    _inL  = new RNBO::SampleValue[kMaxFrames];
    _inR  = new RNBO::SampleValue[kMaxFrames];
    _outL = new RNBO::SampleValue[kMaxFrames];
    _outR = new RNBO::SampleValue[kMaxFrames];

    _coreObject.prepareToProcess(realSR, kMaxFrames);

    // Capture raw pointers — no ObjC message sends or ARC retains on the audio thread.
    RNBO::CoreObject     *core      = &_coreObject;
    RNBO::SampleValue    *inL       = _inL;
    RNBO::SampleValue    *inR       = _inR;
    RNBO::SampleValue    *outL      = _outL;
    RNBO::SampleValue    *outR      = _outR;
    std::atomic<float *> *pcmLPtr   = &_pcmL;
    std::atomic<float *> *pcmRPtr   = &_pcmR;
    std::atomic<int64_t> *framesPtr = &_pcmFrameCount;
    std::atomic<int64_t> *headPtr   = &_playhead;

    AVAudioFormat *format = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:realSR channels:2];

    _sourceNode = [[AVAudioSourceNode alloc]
        initWithFormat:format
        renderBlock:^OSStatus(BOOL *isSilence,
                              const AudioTimeStamp *timestamp,
                              AVAudioFrameCount frameCount,
                              AudioBufferList *outputData) {

            float   *pcmL  = pcmLPtr->load(std::memory_order_acquire);
            float   *pcmR  = pcmRPtr->load(std::memory_order_acquire);
            int64_t  total = framesPtr->load(std::memory_order_relaxed);
            int64_t  pos   = headPtr->load(std::memory_order_relaxed);

            if (pcmL == nullptr || total == 0) {
                // No file loaded — zero output and skip RNBO.
                for (UInt32 ch = 0; ch < outputData->mNumberBuffers; ++ch)
                    memset(outputData->mBuffers[ch].mData, 0,
                           outputData->mBuffers[ch].mDataByteSize);
                *isSilence = YES;
                return noErr;
            }

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

            RNBO::SampleValue *inBufs[2]  = { inL, inR };
            RNBO::SampleValue *outBufs[2] = { outL, outR };
            core->process(inBufs, 2, outBufs, 2, frameCount);

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
    // Playhead is intentionally NOT reset — transport position is preserved across stop/start.
}

- (void)setParameterWithIndex:(int)index value:(float)value {
    _coreObject.setParameterValue(index, value);
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

@end
