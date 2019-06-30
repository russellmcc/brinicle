#include "Brinicle/Thread/Grab_mirror.h"

using namespace Brinicle;

Grab_mirror::Grab_mirror(const std::vector<Parameter_info>& params)
{
    for (const auto& param : params) {
        dsp_grab_count[param.address] = 0u;
        atomic_pending_grabs[param.address].store(0u);
        atomic_pending_ungrabs[param.address].store(0u);
    }
}

void Grab_mirror::grab_from_ui_thread(uint64_t address) { ++atomic_pending_grabs[address]; }

void Grab_mirror::ungrab_from_ui_thread(uint64_t address) { ++atomic_pending_ungrabs[address]; }
