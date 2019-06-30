#include "Brinicle/Glue/Make_kernel_factory.h"
#include "Brinicle/Utilities/Overload.h"

using namespace Brinicle;

using namespace std;
namespace {
struct rust_kernel;

struct glue_event {
    int64_t time;
    uint64_t ty;

    uint64_t param_addr;
    double param_value;
    uint32_t param_ramp_time;

    uint8_t midi_cable;
    uint16_t midi_valid_bytes;
    uint8_t midi_bytes[3];
};
}
extern "C" {
void get_params(void*,
                void (*numeric_param)(void*,
                                      const char*,
                                      uint64_t,
                                      const char*,
                                      uint64_t,
                                      double,
                                      double,
                                      uint64_t,
                                      const char*,
                                      double,
                                      const uint64_t*,
                                      uint64_t),
                void*,
                void (*indexed_param)(void*,
                                      const char*,
                                      uint64_t,
                                      const char*,
                                      uint64_t,
                                      const char* const*,
                                      uint64_t,
                                      uint64_t,
                                      const uint64_t*,
                                      uint64_t));
rust_kernel* create_kernel(uint32_t input_count, uint32_t output_count, double sample_rate);
void delete_kernel(rust_kernel*);

void set_kernel_parameter(rust_kernel*, uint64_t, double);
double get_kernel_parameter(const rust_kernel*, uint64_t);
uint64_t get_kernel_latency(const rust_kernel*);
void reset_kernel(rust_kernel*);

void process_kernel(rust_kernel*,
                    float* const*,
                    uint64_t channels,
                    uint64_t samples,
                    void*,
                    const glue_event* (*event_stream)(void*));

uint32_t get_kernel_type();

void get_kernel_allowed_channel_formats(void*, void (*format)(void*, int32_t, int32_t));

uint64_t get_has_bypass_param();
uint64_t get_bypass_param();
}

namespace {
struct rust_kernel_deleter {
    using pointer = rust_kernel*;
    void operator()(pointer p) { delete_kernel(p); }
};

using rust_kernel_ptr = std::unique_ptr<rust_kernel, rust_kernel_deleter>;

static const glue_event* glue_event_stream(void* ctx)
{
    auto p = reinterpret_cast<pair<Audio_event_generator, glue_event>*>(ctx);
    auto& generator = p->first;
    auto& event = p->second;
    auto nextEvent = generator();
    if (nextEvent) {
        std::visit(overload {[&](const Parameter_change& param_change) {
                                 event.time = param_change.buffer_offset_time;
                                 event.ty = 0;
                                 event.param_addr = param_change.address;
                                 event.param_value = param_change.value;
                             },
                             [&](const Ramped_parameter_change& param_change) {
                                 event.time = param_change.buffer_offset_time;
                                 event.ty = 1;
                                 event.param_addr = param_change.address;
                                 event.param_value = param_change.value;
                                 event.param_ramp_time = param_change.ramp_length;
                             },
                             [&](const Midi_message& midi_message) {
                                 event.time = midi_message.buffer_offset_time;
                                 event.ty = 2;
                                 event.midi_cable = midi_message.cable;
                                 event.midi_valid_bytes = midi_message.valid_bytes;
                                 std::copy(begin(midi_message.data),
                                           end(midi_message.data),
                                           begin(event.midi_bytes));
                             }},
                   *nextEvent);
        return &event;
    } else {
        return nullptr;
    }
}

class kernel_impl : public Kernel {
public:
    kernel_impl(rust_kernel_ptr kernel_) : kernel(std::move(kernel_)) {}
    ~kernel_impl() override {}

    void set_parameter(uint64_t identifier, float value) override
    {
        set_kernel_parameter(kernel.get(), identifier, value);
    }
    float get_parameter(uint64_t identifier) const override
    {
        return get_kernel_parameter(kernel.get(), identifier);
    }

    uint64_t get_latency() const override { return get_kernel_latency(kernel.get()); }

    void reset() override { reset_kernel(kernel.get()); }

    void process(Deinterleaved_audio deinterleaved_audio, Audio_event_generator events) override
    {
        auto p = make_pair(events, glue_event {});
        process_kernel(kernel.get(),
                       deinterleaved_audio.data,
                       deinterleaved_audio.channel_count,
                       deinterleaved_audio.frame_count,
                       reinterpret_cast<void*>(&p),
                       glue_event_stream);
    }

private:
    rust_kernel_ptr kernel;
};
}

static unique_ptr<Kernel>
make_kernel_impl(uint32_t input_count, uint32_t output_count, double sample_rate)
{
    return make_unique<kernel_impl>(
        rust_kernel_ptr(create_kernel(input_count, output_count, sample_rate)));
}

namespace {
using add_numeric_param_t = std::function<void(std::string,
                                               uint64_t,
                                               std::string,
                                               uint64_t,
                                               double,
                                               double,
                                               uint64_t,
                                               std::string,
                                               double,
                                               std::vector<uint64_t>)>;

using add_indexed_param_t = std::function<void(std::string,
                                               uint64_t,
                                               std::string,
                                               uint64_t,
                                               std::vector<std::string>,
                                               uint64_t,
                                               std::vector<uint64_t>)>;

using add_allowed_format_t = std::function<void(int32_t, int32_t)>;
}

static void apply_numeric_fn(void* ctx,
                             const char* ident,
                             uint64_t address,
                             const char* name,
                             uint64_t flags,
                             double min,
                             double max,
                             uint64_t unit,
                             const char* unit_name,
                             double def,
                             const uint64_t* dep_params,
                             uint64_t num_dep_params)
{
    auto fn = reinterpret_cast<add_numeric_param_t*>(ctx);
    (*fn)(std::string(ident),
          address,
          std::string(name),
          flags,
          min,
          max,
          unit,
          unit_name ? std::string(unit_name) : std::string(),
          def,
          std::vector<uint64_t>(dep_params, dep_params + num_dep_params));
}
static void apply_indexed_fn(void* ctx,
                             const char* ident,
                             uint64_t address,
                             const char* name,
                             uint64_t flags,
                             const char* const* value_strings_c,
                             uint64_t num_values,
                             uint64_t def,
                             const uint64_t* dep_params,
                             uint64_t num_dep_params)
{
    auto fn = reinterpret_cast<add_indexed_param_t*>(ctx);
    vector<string> value_strings(num_values);
    std::transform(
        value_strings_c, value_strings_c + num_values, begin(value_strings), [](const char* c_str) {
            return std::string(c_str);
        });
    (*fn)(std::string(ident),
          address,
          std::string(name),
          flags,
          value_strings,
          def,
          std::vector<uint64_t>(dep_params, dep_params + num_dep_params));
}

static void apply_allowed_format_fn(void* ctx, int32_t input_format, int32_t output_format)
{
    auto fn = reinterpret_cast<add_allowed_format_t*>(ctx);
    (*fn)(input_format, output_format);
}

static std::vector<Parameter_info> get_kernel_impl_params()
{
    std::vector<Parameter_info> retVal;
    add_numeric_param_t addNumeric = [&retVal](std::string ident,
                                               uint64_t address,
                                               std::string name,
                                               uint64_t flags,
                                               double min,
                                               double max,
                                               uint64_t unit,
                                               std::string unit_name,
                                               double def,
                                               std::vector<uint64_t> dep_params) {
        retVal.push_back(Parameter_info {
            std::move(ident),
            address,
            std::move(name),
            uint32_t(flags),
            Numeric_parameter_info {
                min,
                max,
                unit_name != "" ? std::variant<AudioUnitParameterUnit, std::string>(unit_name)
                                : std::variant<AudioUnitParameterUnit, std::string>(
                                    AudioUnitParameterUnit(unit)),
                def},
            std::move(dep_params)});
    };
    add_indexed_param_t addIndexed = [&retVal](std::string ident,
                                               uint64_t address,
                                               std::string name,
                                               uint64_t flags,
                                               std::vector<std::string> value_strings,
                                               uint64_t def,
                                               std::vector<uint64_t> dep_params) {
        retVal.push_back(
            Parameter_info {std::move(ident),
                            address,
                            std::move(name),
                            uint32_t(flags),
                            Indexed_parameter_info {std::move(value_strings), size_t(def)},
                            std::move(dep_params)});
    };

    get_params(&addNumeric, apply_numeric_fn, &addIndexed, apply_indexed_fn);
    return retVal;
}

static vector<Allowed_channel_configuration> get_kernel_allowed_channels()
{
    vector<Allowed_channel_configuration> ret;
    add_allowed_format_t add_format = [&](int32_t input, int32_t output) {
        auto input_channels = input >= 0
            ? std::variant<Any_channel_count, Channel_count> {Channel_count {
                static_cast<uint64_t>(input)}}
            : std::variant<Any_channel_count, Channel_count> {Any_channel_count {}};
        auto output_channels = output >= 0
            ? std::variant<Any_channel_count, Channel_count> {Channel_count {
                static_cast<uint64_t>(output)}}
            : std::variant<Any_channel_count, Channel_count> {Any_channel_count {}};
        ret.emplace_back(Allowed_channel_configuration {input_channels, output_channels});
    };

    get_kernel_allowed_channel_formats(&add_format, apply_allowed_format_fn);
    return ret;
}

namespace {
class Rust_kernel_factory : public KernelFactory {
public:
    Rust_kernel_factory()
        : info_ {get_kernel_type() == 1 ? Type::instrument : Type::effect,
                 get_kernel_allowed_channels(),
                 get_kernel_impl_params(),
                 get_has_bypass_param() ? std::optional<uint64_t>(get_bypass_param())
                                        : std::nullopt}
    {
    }
    const Info& info() const override { return info_; }
    std::unique_ptr<Kernel> make_kernel(uint32_t input_channel_count,
                                        uint32_t output_channel_count,
                                        double sample_rate) const override
    {
        return make_kernel_impl(input_channel_count, output_channel_count, sample_rate);
    }

private:
    Info info_;
};
}

std::unique_ptr<KernelFactory> Brinicle::make_kernel_factory()
{
    return make_unique<Rust_kernel_factory>();
}
