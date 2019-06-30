#pragma once

#include "Brinicle/Kernel/Parameter.h"
#include <atomic>
#include <map>

namespace Brinicle {
class Grab_mirror {
public:
    Grab_mirror(const std::vector<Parameter_info>& params);

    void grab_from_ui_thread(uint64_t address);
    void ungrab_from_ui_thread(uint64_t address);

    template <typename Grab> void check_pending_grabs_from_dsp_thread(Grab grab)
    {
        for (auto& g : atomic_pending_grabs) {
            auto grab_count = g.second.exchange(0u);
            bool was_grabbed = dsp_grab_count.at(g.first) != 0;
            dsp_grab_count[g.first] += grab_count;
            auto is_grabbed = dsp_grab_count.at(g.first) != 0u;
            if (is_grabbed != was_grabbed) {
                grab(g.first);
            }
        }
    }

    template <typename Ungrab> void check_pending_ungrabs_from_dsp_thread(Ungrab ungrab)
    {
        for (auto& g : atomic_pending_ungrabs) {
            auto ungrab_count = g.second.exchange(0u);
            bool was_grabbed = dsp_grab_count.at(g.first) != 0;
            dsp_grab_count[g.first] = ungrab_count > dsp_grab_count[g.first]
                ? 0u
                : dsp_grab_count[g.first] - ungrab_count;
            auto is_grabbed = dsp_grab_count.at(g.first) != 0u;
            if (is_grabbed != was_grabbed) {
                ungrab(g.first);
            }
        }
    }

private:
    std::map<uint64_t, uint64_t> dsp_grab_count;
    std::map<uint64_t, std::atomic<uint64_t>> atomic_pending_grabs;
    std::map<uint64_t, std::atomic<uint64_t>> atomic_pending_ungrabs;
};
}
