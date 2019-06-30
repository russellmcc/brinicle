#pragma once

#include "Brinicle/Thread/UI_parameter.h"
#include <any>
#include <functional>
#include <memory>
#include <vector>

namespace Brinicle {
/// This contains everything `AURCTManager` needs to talk to the Audio Unit.
struct Kernel_ui_interface {
    std::shared_ptr<UI_parameter_set> parameter_set;
    std::vector<Parameter_info> parameters;
    /// Whenever a parameter changes, the passed-in callback will be called with the index and new
    /// value. This should happen until the returned `std::any` is destroyed.
    std::function<std::any(std::function<void(uint64_t, float)>)> subscribe_to_parameter_changes;
};
}
