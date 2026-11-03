// T-061 test fixture: an in-process AUv3 (an AUAudioUnit subclass registered with
// +registerSubclass:…), so the AU hosting tests can check what Apple's AUs can't show:
// a latency that changes (PLUG-013), an aux input bus (PLUG-014), exact MIDI frame offsets
// (PLUG-010) and parameter events (PLUG-015). Registered as aumf:fAke:Embr (a music effect: audio
// in, MIDI in, audio out). Its render allocates nothing (buffers are made in
// allocateRenderResources), so hosting it under the RT trap counts only the host's violations.
//
// Signal: out[c][i] = gain · in[c][i − latency] + sidechainMix · aux[c][i] + impulse[i], where
// impulse[i] = velocity / 127 at the frame of each MIDI note-on in the block. gain (address 0,
// 0…2, default 1) and sidechainMix (address 1, 0…1, default 0) follow parameter events at their
// sample time; ramps jump to the end value at the event's frame (enough for the tests).

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <vector>

#include "AUPluginChecks.h"

// The SDK declares AUInternalRenderBlock nonblocking; this fixture's block isn't annotated (it is
// allocation-free by construction, and the RT trap checks it at runtime like any AU).
#pragma clang diagnostic ignored "-Wfunction-effects"

namespace {

constexpr uint32_t kMaxDelay = 1 << 16;
constexpr uint32_t kMaxFrames = 4096;

struct FakeDSP {
    std::vector<float> in[2], aux[2];
    std::vector<float> delay[2];
    uint32_t writePos = 0;
    uint32_t latency = 0;   // samples, read by render
    float gain = 1.0f;
    float sidechainMix = 0.0f;
    std::atomic<uint64_t> noteOns{0};
    std::atomic<int64_t> lastNoteFrame{-1};
};

} // namespace

@interface DAWTestFakeAudioUnit : AUAudioUnit
- (void)setTestLatency:(NSTimeInterval)seconds;
- (uint64_t)testNoteOns;
@end

// Every live fake, so tests can reach the instance the engine made.
static NSHashTable<DAWTestFakeAudioUnit*>* liveFakes() {
    static NSHashTable* table = [NSHashTable weakObjectsHashTable];
    return table;
}

@implementation DAWTestFakeAudioUnit {
    AUAudioUnitBusArray* _inputs;
    AUAudioUnitBusArray* _outputs;
    AUParameterTree* _tree;
    FakeDSP* _dsp;
    NSTimeInterval _latency;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError**)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (self == nil) return nil;
    _dsp = new FakeDSP;
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AUAudioUnitBus* main = [[AUAudioUnitBus alloc] initWithFormat:format error:nil];
    AUAudioUnitBus* aux = [[AUAudioUnitBus alloc] initWithFormat:format error:nil];
    AUAudioUnitBus* out = [[AUAudioUnitBus alloc] initWithFormat:format error:nil];
    _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[ main, aux ]];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[ out ]];

    const AudioUnitParameterOptions flags =
        kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_CanRamp;
    AUParameter* gain = [AUParameterTree createParameterWithIdentifier:@"gain" name:@"Gain" address:0 min:0 max:2
                                                                  unit:kAudioUnitParameterUnit_LinearGain unitName:nil
                                                                 flags:flags valueStrings:nil dependentParameters:nil];
    AUParameter* mix = [AUParameterTree createParameterWithIdentifier:@"sidechain" name:@"Sidechain Mix" address:1
                                                                  min:0 max:1 unit:kAudioUnitParameterUnit_Generic
                                                             unitName:nil flags:flags valueStrings:nil
                                                  dependentParameters:nil];
    gain.value = 1;
    mix.value = 0;
    _tree = [AUParameterTree createTreeWithChildren:@[ gain, mix ]];
    FakeDSP* dsp = _dsp;
    _tree.implementorValueObserver = ^(AUParameter* param, AUValue value) {
        if (param.address == 0) dsp->gain = value;
        if (param.address == 1) dsp->sidechainMix = value;
    };
    _tree.implementorValueProvider = ^AUValue(AUParameter* param) {
        return param.address == 0 ? dsp->gain : dsp->sidechainMix;
    };
    @synchronized(liveFakes()) {
        [liveFakes() addObject:self];
    }
    return self;
}

- (void)dealloc {
    delete _dsp;
}

- (AUAudioUnitBusArray*)inputBusses { return _inputs; }
- (AUAudioUnitBusArray*)outputBusses { return _outputs; }
- (AUParameterTree*)parameterTree { return _tree; }
- (NSTimeInterval)latency { return _latency; }
- (NSTimeInterval)tailTime { return 0; }
- (BOOL)providesUserInterface { return NO; }

// PLUG-013: changes the reported latency (and the delay the DSP applies), with KVO.
- (void)setTestLatency:(NSTimeInterval)seconds {
    [self willChangeValueForKey:@"latency"];
    _latency = seconds;
    const double rate = _outputs[0].format.sampleRate;
    _dsp->latency = static_cast<uint32_t>(std::min<double>(kMaxDelay - 1, std::round(seconds * rate)));
    [self didChangeValueForKey:@"latency"];
}

- (uint64_t)testNoteOns { return _dsp->noteOns.load(); }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError**)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    for (int c = 0; c < 2; ++c) {
        _dsp->in[c].assign(kMaxFrames, 0);
        _dsp->aux[c].assign(kMaxFrames, 0);
        _dsp->delay[c].assign(kMaxDelay, 0);
    }
    _dsp->writePos = 0;
    _dsp->latency = static_cast<uint32_t>(std::round(_latency * _outputs[0].format.sampleRate));
    return YES;
}

- (AUInternalRenderBlock)internalRenderBlock {
    FakeDSP* dsp = _dsp;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* timestamp,
                              AUAudioFrameCount frames, NSInteger outputBus, AudioBufferList* output,
                              const AURenderEvent* events, AURenderPullInputBlock pull) {
        (void)outputBus;
        if (frames > kMaxFrames) return kAudioUnitErr_TooManyFramesToProcess;
        // Pull the main and aux inputs into our own buffers.
        for (NSInteger bus = 0; bus < 2; ++bus) {
            std::vector<float>* dst = bus == 0 ? dsp->in : dsp->aux;
            struct {
                AudioBufferList list;
                AudioBuffer second;
            } storage;
            AudioBufferList* list = &storage.list;
            list->mNumberBuffers = 2;
            for (int c = 0; c < 2; ++c) list->mBuffers[c] = AudioBuffer{1, frames * 4, dst[c].data()};
            AudioUnitRenderActionFlags pullFlags = 0;
            if (pull == nil || pull(&pullFlags, timestamp, frames, bus, list) != noErr) {
                for (int c = 0; c < 2; ++c) std::memset(dst[c].data(), 0, frames * 4);
            } else {
                for (int c = 0; c < 2; ++c)
                    if (list->mBuffers[c].mData != dst[c].data())
                        std::memcpy(dst[c].data(), list->mBuffers[c].mData, frames * 4);
            }
        }
        float* out[2];
        for (int c = 0; c < 2; ++c) {
            if (output->mBuffers[c].mData == nullptr) output->mBuffers[c].mData = dsp->in[c].data();
            out[c] = static_cast<float*>(output->mBuffers[c].mData);
        }
        // Events (parameters and MIDI) apply from their frame; the output is computed after, per
        // frame, so a parameter event changes everything from its frame on.
        const AURenderEvent* event = events;
        for (AUAudioFrameCount i = 0; i < frames; ++i) {
            float impulse = 0;
            while (event != nullptr) {
                const int64_t at = event->head.eventSampleTime - static_cast<int64_t>(timestamp->mSampleTime);
                if (at > static_cast<int64_t>(i)) break;
                if (event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp) {
                    if (event->parameter.parameterAddress == 0) dsp->gain = event->parameter.value;
                    if (event->parameter.parameterAddress == 1) dsp->sidechainMix = event->parameter.value;
                } else if (event->head.eventType == AURenderEventMIDI && event->MIDI.length == 3 &&
                           (event->MIDI.data[0] & 0xF0) == 0x90 && event->MIDI.data[2] > 0) {
                    impulse += event->MIDI.data[2] / 127.0f;
                    dsp->noteOns.fetch_add(1, std::memory_order_relaxed);
                    dsp->lastNoteFrame.store(static_cast<int64_t>(timestamp->mSampleTime) + i, std::memory_order_relaxed);
                }
                event = event->head.next;
            }
            for (int c = 0; c < 2; ++c) {
                const float x = dsp->in[c][i], s = dsp->aux[c][i];
                dsp->delay[c][dsp->writePos] = x;
                const float delayed = dsp->delay[c][(dsp->writePos + kMaxDelay - dsp->latency) % kMaxDelay];
                out[c][i] = dsp->gain * delayed + dsp->sidechainMix * s + impulse;
            }
            dsp->writePos = (dsp->writePos + 1) % kMaxDelay;
        }
        // Events past the block (shouldn't happen) are dropped.
        if (flags) *flags = 0;
        return noErr;
    };
}

@end

namespace daw::testing {

bool registerFakeAudioUnit() {
    static const bool registered = [] {
        AudioComponentDescription desc{'aumf', 'fAke', 'Embr', 0, 0};
        [AUAudioUnit registerSubclass:[DAWTestFakeAudioUnit class]
               asComponentDescription:desc
                                 name:@"Ember: Fake AU"
                              version:1];
        return AudioComponentFindNext(nullptr, &desc) != nullptr;
    }();
    return registered;
}

namespace {
NSArray<DAWTestFakeAudioUnit*>* fakes() {
    @synchronized(liveFakes()) {
        return liveFakes().allObjects;
    }
}
} // namespace

int liveFakeAudioUnits() {
    @autoreleasepool {
        return static_cast<int>(fakes().count);
    }
}

void setFakeAudioUnitLatency(double seconds) {
    @autoreleasepool {
        for (DAWTestFakeAudioUnit* unit in fakes()) [unit setTestLatency:seconds];
    }
}

uint64_t fakeAudioUnitNoteOns() {
    @autoreleasepool {
        uint64_t total = 0;
        for (DAWTestFakeAudioUnit* unit in fakes()) total += [unit testNoteOns];
        return total;
    }
}

} // namespace daw::testing
