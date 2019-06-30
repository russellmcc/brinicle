#pragma once

#include "Brinicle/Kernel/Parameter.h"
#include <AudioToolbox/AudioToolbox.h>
#include <array>
#include <functional>
#include <memory>
#include <optional>

namespace Brinicle {

struct Parameter_change {
    int64_t buffer_offset_time;
    uint64_t address;
    float value;
};

struct Ramped_parameter_change {
    int64_t buffer_offset_time;
    uint64_t address;
    float value;
    uint32_t ramp_length;
};

struct Midi_message {
    int64_t buffer_offset_time;
    uint8_t cable;

    // NOTE - currently, sysex is unsupported and max size of MIDI message is 3.
    uint16_t valid_bytes;
    std::array<uint8_t, 3> data;
};

using Audio_event = std::variant<Parameter_change, Ramped_parameter_change, Midi_message>;

inline int64_t get_buffer_offset_time(const Audio_event& event)
{
    return std::visit([](const auto& sub_event) { return sub_event.buffer_offset_time; }, event);
}

// Since apple provides events as a weird linked list, we can't represent an
// event list as a span<event>.  Instead, we use a generator idiom.  If we
// had C++ clients of this code, it's probably best to represent this by a
// ranges_v3 iterator_range.
using Audio_event_generator = std::function<std::optional<Audio_event>()>;

}
