#pragma once

#include <cstddef>

namespace Brinicle {

struct Deinterleaved_audio {
    size_t channel_count;
    size_t frame_count;

    float* const* data;
};

}
