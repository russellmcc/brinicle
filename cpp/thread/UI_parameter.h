#pragma once

#include "Brinicle/Kernel/Parameter.h"

namespace Brinicle {
/// Represents a parameter that is being interacted with.
/// Grabbed parameter cannot outlive its UI_parameter_set
class Grabbed_parameter {
public:
    virtual ~Grabbed_parameter();
    virtual void set_parameter(float value) = 0;
};

/// This abstraction covers parameters that will be interacted with on the UI.
/// The only difference bretween this and `Parameter_set` is parameters in a `UI_parameter_set`
/// can't be changed without being "grabbed" first.
class UI_parameter_set {
public:
    virtual ~UI_parameter_set();
    virtual std::unique_ptr<Grabbed_parameter> grab_parameter(uint64_t identifier) = 0;
    virtual float get_parameter(uint64_t identifier) const = 0;
};

using Parameter_state = std::map<uint64_t, float>;
Parameter_state get_param_state(const UI_parameter_set& parameter_set,
                                const std::vector<Parameter_info>& parameters);
}
