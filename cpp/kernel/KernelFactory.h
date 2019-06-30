#pragma once
#include "Brinicle/Kernel/Kernel.h"
#include "Brinicle/Kernel/Parameter.h"
#include <vector>

namespace Brinicle {

struct Any_channel_count {
};
struct Channel_count {
    uint64_t channels;
};

struct Allowed_channel_configuration {
    std::variant<Any_channel_count, Channel_count> input_channels;
    std::variant<Any_channel_count, Channel_count> output_channels;
};

/// This is the core abstraction layer
class KernelFactory {
public:
    enum class Type {
        effect,
        instrument,
    };

    struct Info {
        Type type;
        std::vector<Allowed_channel_configuration> allowed_channel_configurations;
        std::vector<Parameter_info> parameters;
        std::optional<uint64_t> bypass_parameter;
    };

    virtual ~KernelFactory();
    virtual const Info& info() const = 0;
    virtual std::unique_ptr<Kernel> make_kernel(uint32_t input_channel_count,
                                                uint32_t output_channel_count,
                                                double sample_rate) const = 0;
};

}
