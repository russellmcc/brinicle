#include "Brinicle/AUv2/v2impl.h"

extern "C" void* AudioFactory(const AudioComponentDescription*)
{
    return Brinicle::make_audio_factory();
}
