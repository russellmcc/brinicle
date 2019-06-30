#pragma once

#include "ObjC_prefix.h"

#include "Brinicle/React/Kernel_ui_interface.h"
#include "Brinicle/Utilities/Macro_join.h"

#import <AudioToolbox/AudioToolbox.h>

#define AudioUnitImpl MACRO_JOIN(OBJC_PREFIX, _AudioUnitImpl)

@interface AudioUnitImpl : AUAudioUnit
@end

namespace Brinicle {

Kernel_ui_interface plugin_ui_interface_for_audio_unit(AudioUnitImpl* unit);

}
