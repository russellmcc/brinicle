#include "Brinicle/Thread/Wrapped_kernel.h"

using namespace std;
using namespace Brinicle;

Wrapped_kernel::Wrapped_kernel(std::unique_ptr<Kernel> kernel,
                               const std::vector<Parameter_info>& parameters,
                               std::weak_ptr<Host_interface> client)
    : kernel(std::move(kernel))
    , mirror(parameters)
    , grab_mirror(parameters)
    , threaded_ui_parameter_set(this)
    , client(client)
{
}

Wrapped_kernel::~Wrapped_kernel() {}

Wrapped_kernel::Threaded_ui_parameter_set::Threaded_ui_parameter_set(Wrapped_kernel* kernel)
    : kernel(kernel)
{
}

Wrapped_kernel::Threaded_ui_parameter_set::~Threaded_ui_parameter_set() {}

Wrapped_kernel::Threaded_grabbed_parameter::Threaded_grabbed_parameter(
    Threaded_ui_parameter_set* set_,
    uint64_t param_ident_)
    : param_ident(param_ident_), set(set_)
{
    set->kernel->grab_mirror.grab_from_ui_thread(param_ident);
}

Wrapped_kernel::Threaded_grabbed_parameter::~Threaded_grabbed_parameter()
{
    set->kernel->grab_mirror.ungrab_from_ui_thread(param_ident);
}

void Wrapped_kernel::Threaded_grabbed_parameter::set_parameter(float value)
{
    lock_guard<recursive_mutex> guard(set->kernel->ui_lock);
    set->kernel->mirror.set_from_ui_thread(param_ident, value);
}

std::unique_ptr<Grabbed_parameter>
Wrapped_kernel::Threaded_ui_parameter_set::grab_parameter(uint64_t identifier)
{
    return make_unique<Threaded_grabbed_parameter>(this, identifier);
}

float Wrapped_kernel::Threaded_ui_parameter_set::get_parameter(uint64_t identifier) const
{
    lock_guard<recursive_mutex> guard(kernel->ui_lock);
    return kernel->mirror.get_from_ui_thread(identifier);
}

uint64_t Wrapped_kernel::get_latency() const
{
    lock_guard<mutex> guard(dsp_lock);
    return kernel->get_latency();
}

void Wrapped_kernel::sync_from_dsp_thread()
{
    last_dsp_sync_time = std::chrono::steady_clock::now();
    {
        lock_guard<mutex> guard(dsp_lock);
        mirror.sync_from_dsp_thread(
            [=](uint64_t address, float value) { kernel->set_parameter(address, value); },
            [=](uint64_t address) { return kernel->get_parameter(address); });
    }
    auto locked_client = client.lock();
    if (locked_client) {
        {
            lock_guard<mutex> guard(dsp_lock);
            grab_mirror.check_pending_grabs_from_dsp_thread(
                [&locked_client](uint64_t address) { locked_client->grab(address); });
        }
        locked_client->update_host();
        {
            lock_guard<mutex> guard(dsp_lock);
            grab_mirror.check_pending_ungrabs_from_dsp_thread(
                [&locked_client](uint64_t address) { locked_client->ungrab(address); });
        }
    }
}

void Wrapped_kernel::set_parameter(uint64_t identifier, float value)
{
    lock_guard<mutex> guard(dsp_lock);
    kernel->set_parameter(identifier, value);
}

float Wrapped_kernel::get_parameter(uint64_t identifier) const
{
    lock_guard<mutex> guard(dsp_lock);
    return kernel->get_parameter(identifier);
}

void Wrapped_kernel::reset()
{
    lock_guard<mutex> guard(dsp_lock);
    kernel->reset();
}

void Wrapped_kernel::process(Deinterleaved_audio interleaved_audio, Audio_event_generator events)
{
    lock_guard<mutex> guard(dsp_lock);
    kernel->process(std::move(interleaved_audio), std::move(events));
}

std::chrono::seconds Wrapped_kernel::dsp_disabled_duration = 1s;

Wrapped_kernel::Host_interface::~Host_interface() {}
