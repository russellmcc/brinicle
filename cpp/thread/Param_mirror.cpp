#include "Brinicle/Thread/Param_mirror.h"
#include "Brinicle/Utilities/Overload.h"

using namespace Brinicle;

Param_mirror::Param_mirror(const std::vector<Parameter_info>& params)
{
    for (const auto& param : params) {
        ui_param_mirror[param.address] = std::visit(
            overload {[](const Numeric_parameter_info& info) -> float {
                          return double(info.default_value);
                      },
                      [](const Indexed_parameter_info& info) -> float {
                          return double(info.default_value);
                      }},
            param.info);
        atomic_mirror[param.address].store(
            std::visit(overload {[](const Numeric_parameter_info& info) -> float {
                                     return double(info.default_value);
                                 },
                                 [](const Indexed_parameter_info& info) -> float {
                                     return double(info.default_value);
                                 }},
                       param.info));
    }
    dsp_param_mirror = ui_param_mirror;
}

Param_mirror::~Param_mirror() {}

float Param_mirror::get_from_ui_thread(uint64_t address) const
{
    return ui_param_mirror.at(address);
}

void Param_mirror::set_from_ui_thread(uint64_t address, float value)
{
    ui_param_mirror[address] = value;
    atomic_mirror[address].store(value);
}
