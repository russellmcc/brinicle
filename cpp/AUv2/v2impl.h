#pragma once

#include "Brinicle/React/Kernel_ui_interface.h"
#include <functional>
#include <memory>

namespace Brinicle {
Kernel_ui_interface plugin_ui_interface_for_audio_unit(AudioUnit unit);
void* make_audio_factory();
}
