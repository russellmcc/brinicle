#pragma once
#include "Brinicle/Kernel/Kernel.h"
#include "Brinicle/Thread/Event_stream.h"
#include "Brinicle/Thread/Grab_mirror.h"
#include "Brinicle/Thread/Param_mirror.h"
#include "Brinicle/Thread/UI_parameter.h"
#include <atomic>
#include <chrono>
#include <mutex>

namespace Brinicle {
/// Wraps a kernel to allow access from multiple threads.
class Wrapped_kernel : public Parameter_set {
public:
    class Host_interface {
    public:
        virtual ~Host_interface();

        /// Tell host about new parameters.  Usually called from DSP thread, unless
        /// DSP thread is inactive.
        virtual void update_host() {}

        /// Start a gesture operation.
        virtual void grab(uint64_t) {}

        /// End a gesture operation.
        virtual void ungrab(uint64_t) {}
    };

    Wrapped_kernel(std::unique_ptr<Kernel> kernel,
                   const std::vector<Parameter_info>& parameters,
                   std::weak_ptr<Host_interface> client);
    ~Wrapped_kernel();

    UI_parameter_set& ui_parameter_set() { return threaded_ui_parameter_set; }
    const UI_parameter_set& ui_parameter_set() const { return threaded_ui_parameter_set; }

    template <typename F> void sync_from_ui_thread(F f)
    {
        std::lock_guard<std::recursive_mutex> guard(ui_lock);
        mirror.sync_from_ui_thread(std::move(f));
        std::chrono::time_point<std::chrono::steady_clock> last_time = last_dsp_sync_time.load();

        auto time_since_sync = last_time
                == std::chrono::time_point<std::chrono::steady_clock>::min()
            ? dsp_disabled_duration
            : std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now()
                                                               - last_time);

        if (time_since_sync >= dsp_disabled_duration) {
            sync_from_dsp_thread();
        }
    }

    void sync_from_dsp_thread();

    void set_parameter(uint64_t identifier, float value) override;
    uint64_t get_latency() const;
    float get_parameter(uint64_t identifier) const override;
    void reset();
    void process(Deinterleaved_audio interleaved_audio, Audio_event_generator events);

private:
    std::unique_ptr<Kernel> kernel;
    Param_mirror mirror;
    Grab_mirror grab_mirror;
    mutable std::recursive_mutex ui_lock;
    mutable std::mutex dsp_lock;
    static std::chrono::seconds dsp_disabled_duration;
    std::atomic<std::chrono::time_point<std::chrono::steady_clock>> last_dsp_sync_time = {
        std::chrono::time_point<std::chrono::steady_clock>::min()};

    class Threaded_ui_parameter_set;

    class Threaded_grabbed_parameter : public Grabbed_parameter {
    public:
        Threaded_grabbed_parameter(Threaded_ui_parameter_set* set, uint64_t param_ident);
        ~Threaded_grabbed_parameter() override;
        void set_parameter(float value) override;

    private:
        uint64_t param_ident;
        Threaded_ui_parameter_set* set;
    };

    class Threaded_ui_parameter_set : public UI_parameter_set {
    public:
        Threaded_ui_parameter_set(Wrapped_kernel* kernel);
        ~Threaded_ui_parameter_set();

        std::unique_ptr<Grabbed_parameter> grab_parameter(uint64_t identifier) override;
        float get_parameter(uint64_t identifier) const override;

    private:
        friend class Threaded_grabbed_parameter;
        Wrapped_kernel* kernel;
    };
    friend class Threaded_ui_parameter_set;
    friend class Threaded_grabbed_parameter;
    Threaded_ui_parameter_set threaded_ui_parameter_set;
    std::weak_ptr<Host_interface> client;
};

inline Parameter_state get_ui_state(Wrapped_kernel& kernel,
                                    const std::vector<Parameter_info>& parameters)
{
    return get_param_state(kernel.ui_parameter_set(), parameters);
}

inline std::shared_ptr<UI_parameter_set>
ui_parameter_set_for_kernel(std::shared_ptr<Wrapped_kernel> kernel)
{
    return std::shared_ptr<UI_parameter_set>(kernel, &kernel->ui_parameter_set());
}

}
