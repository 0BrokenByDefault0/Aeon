#import "AeonDSPAudioUnit.h"
#include "AeonDSPKernel.hpp"
#include <vector>

@implementation AeonDSPAudioUnit {
    AUAudioUnitBusArray *_inputs, *_outputs;
    AeonDSP::Kernel _kernel;
    std::vector<float> _storage;
    float *_pointers[AeonDSP::channels];
    double _rate;
}
+ (AVAudioUnitEffect *)makeNode {
    AudioComponentDescription description = {kAudioUnitType_Effect, 'aepq', 'Aeon', 0, 0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:self asComponentDescription:description name:@"Aeon: Parametric DSP" version:1];
    });
    return [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:description];
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AUAudioUnitBus *input = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    AUAudioUnitBus *output = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!input || !output) return nil;
    input.maximumChannelCount = AeonDSP::channels;
    output.maximumChannelCount = AeonDSP::channels;
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[input]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[output]];
    self.maximumFramesToRender = 4096;
    _rate = 48000;
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (NSTimeInterval)latency { return AeonDSP::lookahead / _rate; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *format = _outputs[0].format;
    if (format.commonFormat != AVAudioPCMFormatFloat32 || format.isInterleaved ||
        format.channelCount == 0 || format.channelCount > AeonDSP::channels ||
        ![_inputs[0].format isEqual:format]) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    _rate = format.sampleRate;
    _kernel.prepare(_rate);
    _storage.resize(self.maximumFramesToRender * format.channelCount);
    for (unsigned c = 0; c < format.channelCount; ++c) _pointers[c] = _storage.data() + c * self.maximumFramesToRender;
    return YES;
}
- (BOOL)submitParameters:(NSData *)parameters {
    if (parameters.length != (3 + AeonDSP::filters * 5) * sizeof(double)) return NO;
    const double *p = (const double *)parameters.bytes;
    if (!std::isfinite(p[0]) || p[0] < 0 || p[0] > AeonDSP::filters || !std::isfinite(p[1]) || p[1] < 0 || p[1] > 1) return NO;
    AeonDSP::Configuration config; config.count = int(p[0]); config.gain = p[1]; config.protect = p[2] != 0;
    for (int i = 0; i < config.count; ++i) for (int j = 0; j < 5; ++j) {
        double value = p[3 + i * 5 + j]; if (!std::isfinite(value)) return NO;
        config.coefficients[i][j] = value;
    }
    return _kernel.submit(config);
}
- (uint64_t)overloadCount { return _kernel.overloads.load(std::memory_order_relaxed); }
- (AUInternalRenderBlock)internalRenderBlock {
    AeonDSP::Kernel *kernel = &_kernel;
    float **storage = _pointers;
    const AUAudioFrameCount maximum = self.maximumFramesToRender;
    const unsigned channels = _outputs[0].format.channelCount;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                              AUAudioFrameCount frames, NSInteger bus, AudioBufferList *output,
                              const AURenderEvent *events, AURenderPullInputBlock pull) {
        if (!pull) return kAudioUnitErr_NoConnection;
        if (frames > maximum || channels > AeonDSP::channels || output->mNumberBuffers != channels) return kAudioUnitErr_TooManyFramesToProcess;
        for (unsigned c = 0; c < channels; ++c) {
            if (!output->mBuffers[c].mData) output->mBuffers[c].mData = storage[c];
            output->mBuffers[c].mDataByteSize = frames * sizeof(float);
        }
        AUAudioUnitStatus status = pull(flags, time, frames, 0, output);
        if (status) return status;
        float *pointers[AeonDSP::channels];
        for (unsigned c = 0; c < channels; ++c) pointers[c] = (float *)output->mBuffers[c].mData;
        kernel->process(pointers, int(channels), int(frames));
        return noErr;
    };
}
@end
