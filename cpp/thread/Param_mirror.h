#pragma once
#include "Brinicle/Kernel/Parameter.h"
#include "readerwriterqueue.h"
#include <atomic>
#include <map>

namespace Brinicle {

// A `Param_mirror` is responsible for creating a UI copy
// of the set of parameters of a kernel, so that manipulations
// can happen concurrently on both threads.
// We aim for eventual consistency
class Param_mirror {
public:
    Param_mirror(const std::vector<Parameter_info>& params);
    ~Param_mirror();

    float get_from_ui_thread(uint64_t address) const;
    void set_from_ui_thread(uint64_t address, float value);

    // "f" is the function to set a parameter.
    // "g" is the function to get a parameter.
    // "grab" is the function to grab/ungrab a parameter.
    template <typename F, typename G> void sync_from_dsp_thread(F f, G g)
    {
        // Copy atomic changes to the dsp thread.
        for (const auto& param : atomic_mirror) {
            auto v = param.second.load();
            if (v != dsp_param_mirror.at(param.first)) {
                dsp_param_mirror[param.first] = v;
                f(param.first, v);
            }
        }

        // Send everything that has changed to the ui thread.
        for (const auto& param : dsp_param_mirror) {
            auto v = g(param.first);
            if (param.second != v) {
                dsp_param_mirror[param.first] = v;
                atomic_mirror[param.first].store(v);
            }
        }
    }

    template <typename F> void sync_from_ui_thread(F f)
    {
        // Copy atomic changes to the ui thread.
        for (const auto& param : atomic_mirror) {
            auto v = param.second.load();
            if (v != ui_param_mirror.at(param.first)) {
                ui_param_mirror[param.first] = v;
                f(param.first, v);
            }
        }
    }

private:
    std::map<uint64_t, float> ui_param_mirror;
    std::map<uint64_t, float> dsp_param_mirror;
    std::map<uint64_t, std::atomic<float>> atomic_mirror;
};
}
