#include "Brinicle/Thread/UI_parameter.h"

using namespace Brinicle;

Parameter_state Brinicle::get_param_state(const UI_parameter_set& parameter_set,
                                          const std::vector<Parameter_info>& parameters)
{
    Parameter_state ret;
    for (const auto& param : parameters) {
        ret[param.address] = parameter_set.get_parameter(param.address);
    }
    return ret;
}

Grabbed_parameter::~Grabbed_parameter() {}
UI_parameter_set::~UI_parameter_set() {}
