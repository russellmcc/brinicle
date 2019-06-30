#pragma once

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

struct BufferedAudioBus {
    AUAudioUnitBus* bus = nullptr;
    AUAudioFrameCount maxFrames = 0;

    AVAudioPCMBuffer* pcmBuffer = nullptr;

    AudioBufferList const* originalAudioBufferList = nullptr;
    AudioBufferList* mutableAudioBufferList = nullptr;

    void init(AVAudioFormat* defaultFormat, AVAudioChannelCount maxChannels);
    void allocateRenderResources(AUAudioFrameCount inMaxFrames);
    void deallocateRenderResources();
};

struct BufferedOutputBus : BufferedAudioBus {
    void prepareOutputBufferList(AudioBufferList* outBufferList, AVAudioFrameCount frameCount);
};

struct BufferedInputBus : BufferedAudioBus {
    AUAudioUnitStatus pullInput(AudioUnitRenderActionFlags* actionFlags,
                                AudioTimeStamp const* timestamp,
                                AVAudioFrameCount frameCount,
                                NSInteger inputBusNumber,
                                AURenderPullInputBlock pullInputBlock);

    void prepareInputBufferList();
};
