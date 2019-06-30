#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <map>
#include <string>
#include <variant>
#include <vector>

namespace Brinicle {

struct Numeric_parameter_info {
    double min;
    double max;

    std::variant<AudioUnitParameterUnit, std::string> unit;

    double default_value;
};

struct Indexed_parameter_info {
    std::vector<std::string> value_strings;

    size_t default_value;
};

struct Parameter_info {
    std::string identifier_string;
    uint64_t address;

    std::string name;

    AudioUnitParameterOptions flags;

    std::variant<Numeric_parameter_info, Indexed_parameter_info> info;

    std::vector<uint64_t> dependent_parameters;
};

class Parameter_set {
public:
    virtual ~Parameter_set();
    virtual void set_parameter(uint64_t identifier, float value) = 0;
    virtual float get_parameter(uint64_t identifier) const = 0;
};

void apply_defaults(Parameter_set& parameter_set, const std::vector<Parameter_info>& parameters);

using Parameter_state = std::map<uint64_t, float>;
Parameter_state get_param_state(const Parameter_set& parameter_set,
                                const std::vector<Parameter_info>& parameters);

Parameter_state get_default_state(const std::vector<Parameter_info>& parameters);

void set_param_state(Parameter_set& parameter_set,
                     const Parameter_state& state,
                     const std::vector<Parameter_info>& parameters);

}
