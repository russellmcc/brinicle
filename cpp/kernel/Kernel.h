#pragma once
#include "Brinicle/Kernel/Audio_event.h"
#include "Brinicle/Kernel/Deinterleaved_audio.h"
#include "Brinicle/Kernel/Parameter.h"
#include <map>
#include <memory>

namespace Brinicle {
/// Represents the "kernel" of DSP processing.  This is a single threaded object.
class Kernel : public Parameter_set {
public:
    virtual ~Kernel();

    virtual void reset() = 0;

    virtual void process(Deinterleaved_audio interleaved_audio, Audio_event_generator events) = 0;

    virtual uint64_t get_latency() const = 0;
};
}
