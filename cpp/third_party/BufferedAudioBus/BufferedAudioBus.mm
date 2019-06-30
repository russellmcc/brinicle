#include "BufferedAudioBus.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

void BufferedAudioBus::init(AVAudioFormat* defaultFormat, AVAudioChannelCount maxChannels)
{
    maxFrames = 0;
    pcmBuffer = nullptr;
    originalAudioBufferList = nullptr;
    mutableAudioBufferList = nullptr;

    bus = [[AUAudioUnitBus alloc] initWithFormat:defaultFormat error:nil];

    bus.maximumChannelCount = maxChannels;
}

void BufferedAudioBus::allocateRenderResources(AUAudioFrameCount inMaxFrames)
{
    maxFrames = inMaxFrames;

    pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:bus.format frameCapacity:maxFrames];

    originalAudioBufferList = pcmBuffer.audioBufferList;
    mutableAudioBufferList = pcmBuffer.mutableAudioBufferList;
}

void BufferedAudioBus::deallocateRenderResources()
{
    pcmBuffer = nullptr;
    originalAudioBufferList = nullptr;
    mutableAudioBufferList = nullptr;
}

void BufferedOutputBus::prepareOutputBufferList(AudioBufferList* outBufferList,
                                                AVAudioFrameCount frameCount)
{
    UInt32 byteSize = frameCount * sizeof(float);
    for (UInt32 i = 0; i < outBufferList->mNumberBuffers; ++i) {
        outBufferList->mBuffers[i].mNumberChannels
            = originalAudioBufferList->mBuffers[i].mNumberChannels;
        outBufferList->mBuffers[i].mDataByteSize = byteSize;
        if (outBufferList->mBuffers[i].mData == nullptr) {
            outBufferList->mBuffers[i].mData = originalAudioBufferList->mBuffers[i].mData;
        }
    }
}

AUAudioUnitStatus BufferedInputBus::pullInput(AudioUnitRenderActionFlags* actionFlags,
                                              AudioTimeStamp const* timestamp,
                                              AVAudioFrameCount frameCount,
                                              NSInteger inputBusNumber,
                                              AURenderPullInputBlock pullInputBlock)
{
    if (pullInputBlock == nullptr) {
        return kAudioUnitErr_NoConnection;
    }

    /*
   Important:
       The Audio Unit must supply valid buffers in
   (inputData->mBuffers[x].mData) and mDataByteSize.
       mDataByteSize must be consistent with frameCount.

       The AURenderPullInputBlock may provide input in those specified
   buffers, or it may replace
       the mData pointers with pointers to memory which it owns and guarantees
   will remain valid
       until the next render cycle.

       See prepareInputBufferList()
  */

    prepareInputBufferList();

    return pullInputBlock(
        actionFlags, timestamp, frameCount, inputBusNumber, mutableAudioBufferList);
}

void BufferedInputBus::prepareInputBufferList()
{
    UInt32 byteSize = maxFrames * sizeof(float);

    mutableAudioBufferList->mNumberBuffers = originalAudioBufferList->mNumberBuffers;

    for (UInt32 i = 0; i < originalAudioBufferList->mNumberBuffers; ++i) {
        mutableAudioBufferList->mBuffers[i].mNumberChannels
            = originalAudioBufferList->mBuffers[i].mNumberChannels;
        mutableAudioBufferList->mBuffers[i].mData = originalAudioBufferList->mBuffers[i].mData;
        mutableAudioBufferList->mBuffers[i].mDataByteSize = byteSize;
    }
}
