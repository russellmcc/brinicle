#include "Brinicle/Kernel/Parameter.h"

using namespace Brinicle;

Parameter_set::~Parameter_set() {}

void Brinicle::apply_defaults(Parameter_set& parameter_set,
                              const std::vector<Parameter_info>& parameters)
{
    set_param_state(parameter_set, get_default_state(parameters), parameters);
}

Parameter_state Brinicle::get_default_state(const std::vector<Parameter_info>& parameters)
{
    auto get_default = [](const auto& info) -> float { return info.default_value; };

    Parameter_state ret;
    for (const auto& param : parameters) {
        ret[param.address] = std::visit(get_default, param.info);
    }
    return ret;
}

Parameter_state Brinicle::get_param_state(const Parameter_set& parameter_set,
                                          const std::vector<Parameter_info>& parameters)
{
    Parameter_state ret;
    for (const auto& param : parameters) {
        ret[param.address] = parameter_set.get_parameter(param.address);
    }
    return ret;
}

void Brinicle::set_param_state(Parameter_set& parameter_set,
                               const Parameter_state& state,
                               const std::vector<Parameter_info>& parameters)
{
    for (const auto& param : parameters) {
        parameter_set.set_parameter(param.address, state.at(param.address));
    }
}
