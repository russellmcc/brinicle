#pragma once

#import "Brinicle/AUv3/AudioUnitImpl.h"
#include "Brinicle/Utilities/Macro_join.h"
#include "ObjC_prefix.h"
#include "TargetConditionals.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/AUViewController.h>

#define AudioUnitViewController MACRO_JOIN(OBJC_PREFIX, _AudioUnitViewController)

@interface AudioUnitViewController : AUViewController {
    AudioUnitImpl* _audioUnit;
    NSView* _rootView;
}

- (void)setAudioUnit:(AudioUnitImpl*)audioUnit;
- (AudioUnitImpl*)audioUnit;

@end
