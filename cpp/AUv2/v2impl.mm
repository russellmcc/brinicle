#include "Brinicle/AUv2/v2impl.h"
#include "AudioToolbox/AudioToolbox.h"
#include "Brinicle/AUv2/ViewFactory_v2.h"
#include "Brinicle/Glue/Make_kernel_factory.h"
#include "Brinicle/Thread/Event_stream.h"
#include "Brinicle/Thread/Wrapped_kernel.h"
#include "Brinicle/Utilities/Overload.h"
#include <algorithm>
#include <map>
#include <memory>
#include <set>
#include <utility>
#include <variant>
#include <vector>

using namespace Brinicle;

using std::unique_ptr;
using std::make_unique;
using std::variant;
using std::visit;
using std::vector;
using std::pair;

namespace {
struct Property_listener {
    AudioUnitPropertyListenerProc proc;
    void* data;
};
}

namespace {
struct Render_callback {
    AURenderCallback callback;
    void* data;
    bool operator<(const Render_callback& rhs) const
    {
        return callback < rhs.callback || data < rhs.data;
    }
};
}

namespace {
class Running_timer {
public:
    Running_timer(NSTimer* timer_) : timer(timer_) {}
    Running_timer(const Running_timer&) = delete;
    Running_timer& operator=(const Running_timer&) = delete;
    ~Running_timer()
    {
        if (timer) {
            [timer invalidate];
        }
    }

private:
    NSTimer* timer;
};
}

namespace {
struct Preallocated_buffer {
    bool should_allocate = true;
    vector<vector<float>> buffer_backing;
};
}

namespace {
struct Instance_data;
class Instance_threaded_kernel_client : public Wrapped_kernel::Host_interface {
public:
    Instance_threaded_kernel_client(Instance_data*);
    ~Instance_threaded_kernel_client() {}
    void update_host() override;
    void grab(uint64_t parameter) override;
    void ungrab(uint64_t parameter) override;

private:
    Instance_data* data;
};
}

namespace {
struct Instance_data {
    Instance_data() : kernel_client(std::make_shared<Instance_threaded_kernel_client>(this)) {}
    AudioUnit audio_unit;
    std::recursive_mutex host_mutex;
    std::unique_ptr<KernelFactory> processor;
    KernelFactory::Info plugin_info;
    std::map<std::string, uint64_t> id_to_address;
    std::map<uint64_t, std::string> address_to_id;
    Parameter_state host_mirror;
    std::shared_ptr<Instance_threaded_kernel_client> kernel_client;
    std::shared_ptr<Wrapped_kernel> kernel;

    std::multimap<int64_t, Audio_event> next_buffer_events;

    // kAudioUnitProperty_StreamFormat
    std::optional<AudioStreamBasicDescription> input_format;
    AudioStreamBasicDescription output_format;

    uint32_t max_frames_per_slice;
    Preallocated_buffer output_buffer;
    Preallocated_buffer input_buffer;
    vector<uint8_t> input_buffer_list_backing;
    AudioBufferList* input_buffer_list = nullptr;
    vector<float*> render_pointers;
    bool process_in_place = true;

    uint64_t latency = 0;

    // kAudioUnitProperty_PresentPreset
    AUPreset present_preset;

    // Property listeners
    std::map<AudioUnitPropertyID, std::vector<Property_listener>> listeners;

    // Render notifications - live version
    std::set<Render_callback> render_callbacks;

    // Pending render notifications - since a callback could add or remove itself.
    std::set<Render_callback> pending_render_callbacks;

    std::pair<std::shared_ptr<Event_stream<uint64_t, float>>,
              std::shared_ptr<Event_emitter<uint64_t, float>>>
        parameter_change_event = make_event<uint64_t, float>();

    // Optimization - only push pending callbacks into the live version if they
    // are dirty.
    bool render_callbacks_dirty = false;

    std::variant<std::nullptr_t, AURenderCallbackStruct, AudioUnitConnection> input;

    std::unique_ptr<Running_timer> timer;
};
}

static void update_host_mirror(Instance_data* data);

Instance_threaded_kernel_client::Instance_threaded_kernel_client(Instance_data* data_) : data(data_)
{
}
void Instance_threaded_kernel_client::update_host()
{
    std::lock_guard<decltype(data->host_mutex)> lock(data->host_mutex);
    update_host_mirror(data);
}

void Instance_threaded_kernel_client::grab(uint64_t parameter)
{
    auto audio_unit = data->audio_unit;
    AudioUnitParameterID address = static_cast<unsigned int>(parameter);
    AudioUnitEvent event;

    event.mEventType = kAudioUnitEvent_BeginParameterChangeGesture;
    event.mArgument.mParameter.mAudioUnit = audio_unit;
    event.mArgument.mParameter.mParameterID = address;
    event.mArgument.mParameter.mScope = kAudioUnitScope_Global,
    event.mArgument.mParameter.mElement = 0;

    //  AUEventListenerNotify(NULL, NULL, &event);
}

void Instance_threaded_kernel_client::ungrab(uint64_t parameter)
{
    auto audio_unit = data->audio_unit;
    AudioUnitParameterID address = static_cast<unsigned int>(parameter);
    AudioUnitEvent event;

    event.mEventType = kAudioUnitEvent_EndParameterChangeGesture;
    event.mArgument.mParameter.mAudioUnit = audio_unit;
    event.mArgument.mParameter.mParameterID = address;
    event.mArgument.mParameter.mScope = kAudioUnitScope_Global,
    event.mArgument.mParameter.mElement = 0;

    //  AUEventListenerNotify(NULL, NULL, &event);
}

static void
preallocate_buffers(Preallocated_buffer& buffer, uint32_t num_samples, uint32_t num_channels)
{
    if (!buffer.should_allocate) {
        return;
    }

    buffer.buffer_backing.resize(num_channels);
    for (auto& buffer_backing : buffer.buffer_backing) {
        buffer_backing.resize(num_samples);
    }
}

namespace {
struct Instance {
    AudioComponentPlugInInterface interface;
    unique_ptr<Instance_data> data;
};
}

enum { s_secret_instance_property = 0x666eee };

static void notify_listeners(Instance_data* data,
                             AudioUnitPropertyID prop,
                             AudioUnitScope scope,
                             AudioUnitElement elem)
{
    auto listeners = data->listeners.find(prop);
    if (listeners != data->listeners.end()) {
        for (const auto& listener : listeners->second) {
            listener.proc(listener.data, data->audio_unit, prop, scope, elem);
        }
    }
}

static AudioStreamBasicDescription default_format(double sample_rate, uint32_t num_channels)
{
    AudioStreamBasicDescription ret;
    memset(&ret, 0u, sizeof(AudioStreamBasicDescription));
    ret.mSampleRate = sample_rate;
    ret.mChannelsPerFrame = num_channels;
    ret.mFormatID = kAudioFormatLinearPCM;
    ret.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
        | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    ret.mBitsPerChannel = 8 * sizeof(float);
    ret.mFramesPerPacket = 1;
    ret.mBytesPerFrame = 1 * sizeof(float);
    ret.mBytesPerPacket = ret.mBytesPerFrame * ret.mFramesPerPacket;

    return ret;
}

static AUPreset dummy_preset() { return AUPreset {-1, nullptr}; }

static uint get_default_channel_count(const std::variant<Any_channel_count, Channel_count>& format)
{
    return std::visit(
        overload {[](Any_channel_count) -> uint { return 2; },
                  [](Channel_count count) -> uint { return static_cast<uint>(count.channels); }},
        format);
}

static bool matches_channel_count(uint channel_count,
                                  const std::variant<Any_channel_count, Channel_count>& format)
{
    return std::visit(
        overload {[](Any_channel_count) { return true; },
                  [&](Channel_count count) { return count.channels == channel_count; }},
        format);
}

static OSStatus open(void* instance_void, AudioUnit audio_unit)
{
    const auto instance = reinterpret_cast<Instance*>(instance_void);
    instance->data = make_unique<Instance_data>();
    instance->data->audio_unit = audio_unit;
    instance->data->processor = make_kernel_factory();
    instance->data->plugin_info = instance->data->processor->info();
    instance->data->host_mirror = get_default_state(instance->data->plugin_info.parameters);
    for (const auto& parameter : instance->data->plugin_info.parameters) {
        instance->data->id_to_address[parameter.identifier_string] = parameter.address;
        instance->data->address_to_id[parameter.address] = parameter.identifier_string;
    }

    const auto default_sampling_rate = 44100.f;
    if (instance->data->plugin_info.type == KernelFactory::Type::effect) {
        instance->data->input_format = default_format(
            default_sampling_rate,
            get_default_channel_count(
                instance->data->plugin_info.allowed_channel_configurations[0].input_channels));
    }
    instance->data->output_format = default_format(
        default_sampling_rate,
        get_default_channel_count(
            instance->data->plugin_info.allowed_channel_configurations[0].output_channels));
    instance->data->max_frames_per_slice = 8192u;
    instance->data->present_preset = dummy_preset();
    return noErr;
}

static OSStatus close(void* instance_void)
{
    const auto instance = reinterpret_cast<Instance*>(instance_void);
    instance->data = nullptr;
    return noErr;
}

static void update_latency(Instance_data* data)
{
    auto new_latency = data->kernel ? data->kernel->get_latency() : 0u;
    if (new_latency != data->latency) {
        data->latency = new_latency;
        notify_listeners(data, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0u);
    }
}

static OSStatus initialize(Instance* instance)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    // First, check to see if this is a valid format for us.
    auto input_channel_count = instance->data->input_format
        ? instance->data->input_format->mChannelsPerFrame
        : 0;
    auto output_channel_count = instance->data->output_format.mChannelsPerFrame;
    bool allowed = end(instance->data->plugin_info.allowed_channel_configurations)
        != std::find_if(begin(instance->data->plugin_info.allowed_channel_configurations),
                        end(instance->data->plugin_info.allowed_channel_configurations),
                        [&](auto allowed) {
                            return matches_channel_count(input_channel_count,
                                                         allowed.input_channels)
                                && matches_channel_count(output_channel_count,
                                                         allowed.output_channels);
                            ;
                        });

    if (!allowed) {
        return kAudioUnitErr_FormatNotSupported;
    }

    instance->data->kernel = make_unique<Wrapped_kernel>(
        instance->data->processor->make_kernel(
            instance->data->input_format ? instance->data->input_format->mChannelsPerFrame : 0,
            instance->data->output_format.mChannelsPerFrame,
            instance->data->output_format.mSampleRate),
        instance->data->plugin_info.parameters,
        instance->data->kernel_client);
    set_param_state(*instance->data->kernel,
                    instance->data->host_mirror,
                    instance->data->plugin_info.parameters);
    instance->data->kernel->sync_from_ui_thread([](uint64_t, float) {});
    update_latency(instance->data.get());

    instance->data->timer = make_unique<Running_timer>([NSTimer
        scheduledTimerWithTimeInterval:0.05
                               repeats:YES
                                 block:^(NSTimer*) {
                                     instance->data->kernel->sync_from_ui_thread(
                                         [&](uint64_t address, float value) {
                                             instance->data->parameter_change_event.second->emit(
                                                 address, value);
                                         });
                                 }]);
    ;

    if (instance->data->input_format) {
        // Note that for technical reasons (to avoid copies in the render function),
        // we should allocate enough so we can cover the output as well.
        auto input_channels = std::max(instance->data->input_format->mChannelsPerFrame,
                                       instance->data->output_format.mChannelsPerFrame);
        preallocate_buffers(
            instance->data->input_buffer, instance->data->max_frames_per_slice, input_channels);
        instance->data->input_buffer_list_backing.resize(
            sizeof(AudioBufferList) + sizeof(AudioBuffer) * (input_channels - 1));
        instance->data->input_buffer_list = reinterpret_cast<AudioBufferList*>(
            instance->data->input_buffer_list_backing.data());
    }
    instance->data->render_pointers.resize(
        instance->data->input_format ? std::max(instance->data->input_format->mChannelsPerFrame,
                                                instance->data->output_format.mChannelsPerFrame)
                                     : instance->data->output_format.mChannelsPerFrame);

    // Always allocate the output buffer to the max output so we can render
    // in-place.
    preallocate_buffers(instance->data->output_buffer,
                        instance->data->max_frames_per_slice,
                        static_cast<uint32_t>(instance->data->render_pointers.size()));
    return noErr;
}

static OSStatus uninitialize(Instance* instance)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (instance->data->kernel) {
        instance->data->host_mirror = get_param_state(*instance->data->kernel,
                                                      instance->data->plugin_info.parameters);
        instance->data->timer = nullptr;
    }
    instance->data->kernel = nullptr;
    instance->data->next_buffer_events.clear();

    return noErr;
}

namespace {
struct Property_info {
    UInt32 data_size;
    Boolean writable;
};
}

static variant<OSStatus, Property_info> get_property_info_internal(Instance* instance,
                                                                   AudioUnitPropertyID prop,
                                                                   AudioUnitScope scope,
                                                                   AudioUnitElement elem)
{
    switch (prop) {
    case kAudioUnitProperty_ElementCount: {
        // "ElementCount" is the number of busses in the given scope, used for
        // side-chain, etc.  Currently this is never writable.
        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(UInt32), false};
    }
    case kAudioUnitProperty_StreamFormat: {
        switch (scope) {
        case kAudioUnitScope_Input:
        case kAudioUnitScope_Output:
            return Property_info {sizeof(AudioStreamBasicDescription),
                                  instance->data->kernel == nullptr};
        }
        return kAudioUnitErr_InvalidScope;
    }
    case kAudioUnitProperty_SampleRate:
        if (scope != kAudioUnitScope_Output) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(double), instance->data->kernel == nullptr};
    case kAudioUnitProperty_SupportedNumChannels: {
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {
            static_cast<UInt32>(
                sizeof(AUChannelInfo)
                * instance->data->plugin_info.allowed_channel_configurations.size()),
            false};
    }
    case kAudioUnitProperty_MaximumFramesPerSlice:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(UInt32), instance->data->kernel == nullptr};
    case kAudioUnitProperty_PresentPreset:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(AUPreset), true};
    case kAudioUnitProperty_ClassInfo:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(CFPropertyListRef), true};
    case kAudioUnitProperty_ParameterList:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {
            static_cast<UInt32>(sizeof(AudioUnitParameterID)
                                    * instance->data->plugin_info.parameters.size()
                                - (instance->data->plugin_info.bypass_parameter ? 1 : 0)),
            false};
    case kAudioUnitProperty_ParameterInfo:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        if (std::find_if(begin(instance->data->plugin_info.parameters),
                         end(instance->data->plugin_info.parameters),
                         [&](const auto& parameter) { return parameter.address == elem; })
            == end(instance->data->plugin_info.parameters)) {
            return kAudioUnitErr_InvalidElement;
        }

        return Property_info {sizeof(AudioUnitParameterInfo), false};
    case kAudioUnitProperty_ParameterValueStrings: {
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        auto param = std::find_if(begin(instance->data->plugin_info.parameters),
                                  end(instance->data->plugin_info.parameters),
                                  [&](const auto& parameter) { return parameter.address == elem; });
        if (param == end(instance->data->plugin_info.parameters)) {
            return kAudioUnitErr_InvalidElement;
        }
        if (!std::holds_alternative<Indexed_parameter_info>(param->info)) {
            return kAudioUnitErr_InvalidElement;
        }
        return Property_info {sizeof(CFArrayRef), false};
    }
    case kAudioUnitProperty_Latency:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(Float64), false};
    case kAudioUnitProperty_CocoaUI:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(AudioUnitCocoaViewInfo), false};
    case kAudioUnitProperty_InPlaceProcessing:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(UInt32), true};
    case kAudioUnitProperty_ShouldAllocateBuffer:
        if (scope == kAudioUnitScope_Input && !instance->data->input_format) {
            return kAudioUnitErr_InvalidScope;
        }

        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output) {
            return kAudioUnitErr_InvalidScope;
        }

        return Property_info {sizeof(UInt32), instance->data->kernel == nullptr};
    case kAudioUnitProperty_BypassEffect:
        if (!instance->data->plugin_info.bypass_parameter) {
            return kAudioUnitErr_InvalidProperty;
        }
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(UInt32), true};
    case s_secret_instance_property:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        return Property_info {sizeof(Instance*), false};
    }
    return kAudioUnitErr_InvalidProperty;
}

static OSStatus get_property_info(Instance* instance,
                                  AudioUnitPropertyID prop,
                                  AudioUnitScope scope,
                                  AudioUnitElement elem,
                                  UInt32* data_size,
                                  Boolean* writable)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);
    return visit(overload {[&](Property_info info) -> OSStatus {
                               if (data_size) {
                                   *data_size = info.data_size;
                               }
                               if (writable) {
                                   *writable = info.writable;
                               }
                               return noErr;
                           },
                           [](OSStatus status) -> OSStatus { return status; }},
                 get_property_info_internal(instance, prop, scope, elem));
}

static std::optional<AudioComponentDescription> get_component_description(AudioUnit unit)
{
    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    if (comp) {
        AudioComponentDescription desc;
        if (AudioComponentGetDescription(comp, &desc) == noErr) {
            return desc;
        }
    }
    return std::optional<AudioComponentDescription> {};
}

static OSStatus get_property_internal(Instance* instance,
                                      AudioUnitPropertyID prop,
                                      AudioUnitScope scope,
                                      AudioUnitElement elem,
                                      uint8_t* output_buffer)
{
    // Note that we can only legally call this after we call get_property_info, so
    // any preconditions checked there will automatically be true here.

    switch (prop) {
    case kAudioUnitProperty_ElementCount:
        // "ElementCount" is the number of busses in the given scope
        // Until we support side-chains, instruments have 0 inputs while effects
        // have 1.
        switch (scope) {
        case kAudioUnitScope_Input:
            *reinterpret_cast<UInt32*>(output_buffer) = instance->data->plugin_info.type
                    == KernelFactory::Type::instrument
                ? 0u
                : 1u;
            return noErr;
        case kAudioUnitScope_Output:
            *reinterpret_cast<UInt32*>(output_buffer) = 1u;
            return noErr;
        }
        return kAudioUnitErr_InvalidScope;
    case kAudioUnitProperty_StreamFormat:
        switch (scope) {
        case kAudioUnitScope_Input:
            if (instance->data->input_format) {
                *reinterpret_cast<AudioStreamBasicDescription*>(output_buffer)
                    = *instance->data->input_format;
                return noErr;
            } else {
                return kAudioUnitErr_InvalidScope;
            }
        case kAudioUnitScope_Output:
            *reinterpret_cast<AudioStreamBasicDescription*>(output_buffer)
                = instance->data->output_format;
            return noErr;
        }
        return kAudioUnitErr_InvalidScope;
    case kAudioUnitProperty_SampleRate:
        if (scope != kAudioUnitScope_Output) {
            return kAudioUnitErr_InvalidScope;
        }
        *reinterpret_cast<double*>(output_buffer) = instance->data->output_format.mSampleRate;
        return noErr;
    case kAudioUnitProperty_SupportedNumChannels: {
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        auto channels = reinterpret_cast<AUChannelInfo*>(output_buffer);
        auto convert = overload {[](Any_channel_count) -> int16_t { return -1; },
                                 [](Channel_count count) -> int16_t { return count.channels; }};
        for (size_t i = 0; i < instance->data->plugin_info.allowed_channel_configurations.size();
             ++i) {
            const auto& allowed = instance->data->plugin_info.allowed_channel_configurations[i];
            channels[i].inChannels = std::visit(convert, allowed.input_channels);
            channels[i].outChannels = std::visit(convert, allowed.output_channels);
        }
        return noErr;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice:
        *reinterpret_cast<UInt32*>(output_buffer) = static_cast<UInt32>(
            instance->data->max_frames_per_slice);
        return noErr;
    case kAudioUnitProperty_PresentPreset:
        *reinterpret_cast<AUPreset*>(output_buffer) = instance->data->present_preset;
        if (instance->data->present_preset.presetName) {
            CFRetain(instance->data->present_preset.presetName);
        }
        return noErr;
    case kAudioUnitProperty_ClassInfo: {
        auto desc = get_component_description(instance->data->audio_unit);
        if (!desc) {
            return kAudioUnitErr_InvalidProperty;
        }
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        auto add_ostype = [&](CFStringRef key, auto type) {
            auto num = CFNumberCreate(nullptr, kCFNumberSInt32Type, &type);
            CFDictionarySetValue(dict, key, num);
            CFRelease(num);
        };
        add_ostype(CFSTR(kAUPresetTypeKey), desc->componentType);
        add_ostype(CFSTR(kAUPresetSubtypeKey), desc->componentSubType);
        add_ostype(CFSTR(kAUPresetManufacturerKey), desc->componentManufacturer);
        add_ostype(CFSTR(kAUPresetVersionKey), 0u);
        CFDictionarySetValue(dict,
                             CFSTR(kAUPresetNameKey),
                             instance->data->present_preset.presetName
                                 ? instance->data->present_preset.presetName
                                 : CFSTR("Untitled"));

        auto settings = instance->data->host_mirror;

        CFMutableDictionaryRef param_dict = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        for (auto setting : settings) {
            CFNumberRef num = CFNumberCreate(NULL, kCFNumberFloatType, &setting.second);
            auto& key_str = instance->data->address_to_id[setting.first];
            auto key = CFStringCreateWithBytes(nullptr,
                                               reinterpret_cast<const uint8_t*>(key_str.data()),
                                               key_str.size(),
                                               kCFStringEncodingUTF8,
                                               false);
            CFDictionarySetValue(param_dict, key, num);
            CFRelease(num);
            CFRelease(key);
        }
        CFDictionarySetValue(dict, CFSTR("settings"), param_dict);
        CFRelease(param_dict);

        *reinterpret_cast<CFMutableDictionaryRef*>(output_buffer) = dict;
        return noErr;
    }
    case kAudioUnitProperty_ParameterList: {
        auto parameters = reinterpret_cast<AudioUnitParameterID*>(output_buffer);
        size_t j = 0;
        for (size_t i = 0u; i < instance->data->plugin_info.parameters.size(); ++i) {
            if (instance->data->plugin_info.parameters[i].address
                != instance->data->plugin_info.bypass_parameter) {
                parameters[j] = static_cast<UInt32>(
                    instance->data->plugin_info.parameters[i].address);
                ++j;
            }
        }
        return noErr;
    }
    case kAudioUnitProperty_ParameterInfo: {
        auto info = reinterpret_cast<AudioUnitParameterInfo*>(output_buffer);
        std::memset(info, 0, sizeof(AudioUnitParameterInfo));
        const auto param = std::find_if(
            begin(instance->data->plugin_info.parameters),
            end(instance->data->plugin_info.parameters),
            [&](const auto& parameter) { return parameter.address == elem; });
        info->cfNameString = CFStringCreateWithBytes(
            nullptr,
            reinterpret_cast<const uint8_t*>(param->identifier_string.data()),
            param->name.size(),
            kCFStringEncodingUTF8,
            false);
        CFStringGetCString(
            info->cfNameString, info->name, sizeof(info->name), kCFStringEncodingUTF8);
        info->flags |= kAudioUnitParameterFlag_CFNameRelease
            | kAudioUnitParameterFlag_HasCFNameString | kAudioUnitParameterFlag_IsReadable
            | kAudioUnitParameterFlag_IsWritable;
        visit(overload {[&](const Numeric_parameter_info& numeric) {
                            info->defaultValue = numeric.default_value;
                            info->minValue = numeric.min;
                            info->maxValue = numeric.max;
                            info->unit = visit(
                                overload {[](AudioUnitParameterUnit unit) { return unit; },
                                          [&](const std::string& custom) {
                                              info->unitName = CFStringCreateWithBytes(
                                                  nullptr,
                                                  reinterpret_cast<const uint8_t*>(custom.data()),
                                                  custom.size(),
                                                  kCFStringEncodingUTF8,
                                                  false);
                                              return kAudioUnitParameterUnit_CustomUnit;
                                          }},
                                numeric.unit);
                        },
                        [&](const Indexed_parameter_info& indexed) {
                            info->defaultValue = indexed.default_value;
                            info->minValue = 0.;
                            info->maxValue = indexed.value_strings.size() - 1;
                            info->unit = kAudioUnitParameterUnit_Indexed;
                        }},
              param->info);
        return noErr;
    }
    case kAudioUnitProperty_ParameterValueStrings: {
        const auto param = std::find_if(
            begin(instance->data->plugin_info.parameters),
            end(instance->data->plugin_info.parameters),
            [&](const auto& parameter) { return parameter.address == elem; });

        auto& info = std::get<Indexed_parameter_info>(param->info);
        auto names = CFArrayCreateMutable(
            nullptr, info.value_strings.size(), &kCFTypeArrayCallBacks);
        for (auto& name_str : info.value_strings) {
            auto cf_name_str = CFStringCreateWithBytes(
                nullptr,
                reinterpret_cast<const uint8_t*>(name_str.data()),
                name_str.size(),
                kCFStringEncodingUTF8,
                false);
            CFArrayAppendValue(names, cf_name_str);
            CFRelease(cf_name_str);
        }
        *reinterpret_cast<CFMutableArrayRef*>(output_buffer) = names;
        return noErr;
    }
    case kAudioUnitProperty_Latency: {
        *reinterpret_cast<double*>(output_buffer) = static_cast<double>(instance->data->latency)
            / instance->data->output_format.mSampleRate;
        return noErr;
    }
    case kAudioUnitProperty_CocoaUI: {
        auto& viewInfo = *reinterpret_cast<AudioUnitCocoaViewInfo*>(output_buffer);
        viewInfo.mCocoaAUViewBundleLocation = copy_view_factory_bundle_url();
        viewInfo.mCocoaAUViewClass[0] = copy_view_factory_class_name();
        return noErr;
    }
    case kAudioUnitProperty_InPlaceProcessing:
        *reinterpret_cast<UInt32*>(output_buffer) = instance->data->process_in_place;
        return noErr;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        *reinterpret_cast<UInt32*>(output_buffer) = (scope == kAudioUnitScope_Output)
            ? instance->data->output_buffer.should_allocate
            : instance->data->input_buffer.should_allocate;
        return noErr;
    case kAudioUnitProperty_BypassEffect:
        *reinterpret_cast<UInt32*>(output_buffer)
            = instance->data->host_mirror[*instance->data->plugin_info.bypass_parameter] == 1.f;
        return noErr;
    case s_secret_instance_property:
        *reinterpret_cast<Instance**>(output_buffer) = instance;
        return noErr;
    }
    return kAudioUnitErr_InvalidProperty;
}

static OSStatus get_property(Instance* instance,
                             AudioUnitPropertyID prop,
                             AudioUnitScope scope,
                             AudioUnitElement elem,
                             uint8_t* output_buffer,
                             UInt32* buffer_size)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    // It's illegal to call this without a data size.
    if (buffer_size == nullptr) {
        return kAudio_ParamError;
    }

    // If the user called this without an output data pointer, just tell them
    // the
    // data size.
    if (output_buffer == nullptr) {
        return get_property_info(instance, prop, scope, elem, buffer_size, nullptr);
    }

    // At this point, we know we are expected to fill in data.  However,
    // weirdly, the host is allowed to ask us for less than the total amount
    // of data we have.  In this case, we're required to give them up to that
    // amount of data.  To support this easily, we call
    // get_property_info_internal
    // to see how much data we need to fill out the whole thing.  If it's more
    // than they gave us, we allocate a new buffer, fill that with data, and
    // copy
    // it to the host's output buffer.  This approach is what apple does in
    // their
    // example code.
    return visit(overload {[&](Property_info info) {
                               uint8_t* buffer_to_fill = output_buffer;
                               vector<uint8_t> temp_buffer;
                               if (info.data_size > *buffer_size) {
                                   temp_buffer.resize(info.data_size);
                                   buffer_to_fill = temp_buffer.data();
                               } else if (info.data_size < *buffer_size) {
                                   *buffer_size = info.data_size;
                               }

                               const auto retVal = get_property_internal(
                                   instance, prop, scope, elem, buffer_to_fill);
                               if (retVal == noErr && buffer_to_fill != output_buffer) {
                                   memcpy(output_buffer, buffer_to_fill, *buffer_size);
                               }
                               return retVal;
                           },
                           [](OSStatus err) { return err; }},
                 get_property_info_internal(instance, prop, scope, elem));
}

static OSStatus validate_format(const AudioStreamBasicDescription& format)
{
    if (format.mFormatID != kAudioFormatLinearPCM) {
        return kAudioUnitErr_FormatNotSupported;
    }
    if (format.mBytesPerFrame != sizeof(float)) {
        return kAudioUnitErr_FormatNotSupported;
    }
    if (format.mFormatFlags
        != (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved)) {
        return kAudioUnitErr_FormatNotSupported;
    }
    return noErr;
}

static OSStatus set_parameter(Instance* instance,
                              AudioUnitParameterID param,
                              AudioUnitScope scope,
                              AudioUnitElement elem,
                              AudioUnitParameterValue value,
                              UInt32 buffer_offset);

static bool formats_equivalent(const AudioStreamBasicDescription& lhs,
                               const AudioStreamBasicDescription& rhs)
{
    return lhs.mChannelsPerFrame == rhs.mChannelsPerFrame && lhs.mFormatID == rhs.mFormatID
        && lhs.mFormatFlags == rhs.mFormatFlags && lhs.mBitsPerChannel == rhs.mBitsPerChannel;
}

static OSStatus set_property(Instance* instance,
                             AudioUnitPropertyID prop,
                             AudioUnitScope scope,
                             AudioUnitElement elem,
                             const uint8_t* data,
                             UInt32 data_size);

static OSStatus set_property_internal(Instance* instance,
                                      AudioUnitPropertyID prop,
                                      AudioUnitScope scope,
                                      AudioUnitElement elem,
                                      const uint8_t* data,
                                      UInt32 data_size)
{
    switch (prop) {
    case kAudioUnitProperty_MaximumFramesPerSlice:
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        if (instance->data->kernel) {
            return kAudioUnitErr_Initialized;
        }
        if (data_size != sizeof(UInt32)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        instance->data->max_frames_per_slice = *reinterpret_cast<const UInt32*>(data);
        return noErr;
    case kAudioUnitProperty_StreamFormat:
        switch (scope) {
        case kAudioUnitScope_Input: {
            if (!instance->data->input_format) {
                // Instruments don't have inputs.
                return kAudioUnitErr_FormatNotSupported;
            }
            if (instance->data->kernel) {
                return kAudioUnitErr_Initialized;
            }
            if (data_size < sizeof(AudioStreamBasicDescription)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            auto new_format = reinterpret_cast<const AudioStreamBasicDescription*>(data);
            auto err = validate_format(*new_format);
            if (err != noErr) {
                return err;
            }
            instance->data->input_format = *new_format;
            instance->data->output_format.mSampleRate = instance->data->input_format->mSampleRate;
            return noErr;
        }
        case kAudioUnitScope_Output: {
            if (instance->data->kernel) {
                return kAudioUnitErr_Initialized;
            }
            if (data_size < sizeof(AudioStreamBasicDescription)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            auto new_format = reinterpret_cast<const AudioStreamBasicDescription*>(data);
            auto err = validate_format(*new_format);
            if (err != noErr) {
                return err;
            }
            instance->data->output_format = *new_format;
            if (instance->data->input_format) {
                instance->data->input_format->mSampleRate
                    = instance->data->output_format.mSampleRate;
            }
            return noErr;
        }
        }
        return kAudioUnitErr_InvalidScope;
    case kAudioUnitProperty_SampleRate:
        if (scope == kAudioUnitScope_Input && !instance->data->input_format) {
            return kAudioUnitErr_InvalidScope;
        }
        if (scope != kAudioUnitScope_Output && scope != kAudioUnitScope_Input) {
            return kAudioUnitErr_InvalidScope;
        }
        if (instance->data->kernel) {
            return kAudioUnitErr_Initialized;
        }
        instance->data->output_format.mSampleRate = *reinterpret_cast<const double*>(data);
        if (instance->data->input_format) {
            instance->data->input_format->mSampleRate = *reinterpret_cast<const double*>(data);
        }
        return noErr;
    case kAudioUnitProperty_PresentPreset: {
        // Data from apple's example code
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        if (data_size != sizeof(instance->data->present_preset)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        auto preset = reinterpret_cast<const AUPreset*>(data);
        if (preset->presetNumber >= 0) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        if (instance->data->present_preset.presetName) {
            CFRelease(instance->data->present_preset.presetName);
        }
        instance->data->present_preset = *preset;
        if (instance->data->present_preset.presetName) {
            CFRetain(instance->data->present_preset.presetName);
        }
        return noErr;
    }
    case kAudioUnitProperty_SetRenderCallback: {
        if (scope != kAudioUnitScope_Input) {
            return kAudioUnitErr_InvalidScope;
        }
        if (data_size != sizeof(AURenderCallbackStruct)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }

        auto callbackStruct = reinterpret_cast<const AURenderCallbackStruct*>(data);
        instance->data->input = *callbackStruct;
        return noErr;
    }
    case kAudioUnitProperty_ClassInfo: {
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        if (data_size != sizeof(CFDictionaryRef)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        auto state = get_default_state(instance->data->plugin_info.parameters);

        const auto dict = reinterpret_cast<const CFDictionaryRef*>(data);

        const auto param_dict = reinterpret_cast<const CFDictionaryRef>(
            CFDictionaryGetValue(*dict, CFSTR("settings")));
        if (param_dict) {
            for (const auto& parameter : instance->data->plugin_info.parameters) {
                auto key = CFStringCreateWithBytes(
                    nullptr,
                    reinterpret_cast<const uint8_t*>(parameter.identifier_string.data()),
                    parameter.identifier_string.size(),
                    kCFStringEncodingUTF8,
                    false);
                CFNumberRef value = reinterpret_cast<CFNumberRef>(
                    CFDictionaryGetValue(param_dict, key));
                CFRelease(key);
                if (value) {
                    float float_value;
                    CFNumberGetValue(value, kCFNumberFloat32Type, &float_value);
                    state[parameter.address] = float_value;
                }
            }
        }
        instance->data->host_mirror = state;
        if (instance->data->kernel) {
            set_param_state(*instance->data->kernel, state, instance->data->plugin_info.parameters);
        }
        return noErr;
    }
    case kAudioUnitProperty_InPlaceProcessing: {
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        if (data_size != sizeof(UInt32)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        instance->data->process_in_place = *reinterpret_cast<const UInt32*>(data);
        return noErr;
    }
    case kAudioUnitProperty_ShouldAllocateBuffer: {
        if (scope == kAudioUnitScope_Input && !instance->data->input_format) {
            return kAudioUnitErr_InvalidScope;
        }
        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output) {
            return kAudioUnitErr_InvalidScope;
        }
        if (data_size != sizeof(UInt32)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        if (instance->data->kernel) {
            return kAudioUnitErr_Initialized;
        }
        auto& should_allocate = (scope == kAudioUnitScope_Input)
            ? instance->data->input_buffer.should_allocate
            : instance->data->output_buffer.should_allocate;
        should_allocate = *reinterpret_cast<const UInt32*>(data);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect: {
        if (!instance->data->plugin_info.bypass_parameter) {
            return kAudioUnitErr_InvalidProperty;
        }
        if (scope != kAudioUnitScope_Global) {
            return kAudioUnitErr_InvalidScope;
        }
        if (data_size != sizeof(UInt32)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }
        set_parameter(
            instance,
            static_cast<AudioUnitParameterID>(*instance->data->plugin_info.bypass_parameter),
            kAudioUnitScope_Global,
            0u,
            *reinterpret_cast<const UInt32*>(data) == 0u ? 0.f : 1.f,
            0u);
        return noErr;
    }
    case kAudioUnitProperty_MakeConnection: {
        if (!instance->data->input_format) {
            return kAudioUnitErr_InvalidProperty;
        }

        if (data_size != sizeof(AudioUnitConnection)) {
            return kAudioUnitErr_InvalidPropertyValue;
        }

        if (scope != kAudioUnitScope_Input) {
            return kAudioUnitErr_InvalidScope;
        }

        if (elem != 0) {
            return kAudioUnitErr_InvalidElement;
        }

        auto connection = reinterpret_cast<const AudioUnitConnection*>(data);

        if (connection && connection->sourceAudioUnit != 0) {
            AudioStreamBasicDescription source_format;
            UInt32 size = sizeof(AudioStreamBasicDescription);

            auto get_format_err = AudioUnitGetProperty(connection->sourceAudioUnit,
                                                       kAudioUnitProperty_StreamFormat,
                                                       kAudioUnitScope_Output,
                                                       connection->sourceOutputNumber,
                                                       &source_format,
                                                       &size);
            if (get_format_err != noErr) {
                return get_format_err;
            }

            if (!formats_equivalent(source_format, *instance->data->input_format)) {
                auto set_format_err = set_property(instance,
                                                   kAudioUnitProperty_StreamFormat,
                                                   kAudioUnitScope_Input,
                                                   elem,
                                                   reinterpret_cast<uint8_t*>(&source_format),
                                                   size);
                if (set_format_err != noErr) {
                    return set_format_err;
                }
            }

            instance->data->input = *connection;

            return noErr;
        }
        instance->data->input = nullptr;
        return noErr;
    }
    }
    return kAudioUnitErr_InvalidProperty;
}

static OSStatus set_property(Instance* instance,
                             AudioUnitPropertyID prop,
                             AudioUnitScope scope,
                             AudioUnitElement elem,
                             const uint8_t* data,
                             UInt32 data_size)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    const auto ret = set_property_internal(instance, prop, scope, elem, data, data_size);
    if (ret == noErr) {
        notify_listeners(instance->data.get(), prop, scope, elem);
    }
    return ret;
}

static OSStatus add_property_listener(Instance* self,
                                      AudioUnitPropertyID prop,
                                      AudioUnitPropertyListenerProc proc,
                                      void* data)
{
    self->data->listeners[prop].emplace_back(Property_listener {proc, data});
    return noErr;
}

static OSStatus remove_property_listener(Instance* self,
                                         AudioUnitPropertyID prop,
                                         AudioUnitPropertyListenerProc proc)
{
    const auto listeners = self->data->listeners.find(prop);
    if (listeners != self->data->listeners.end()) {
        listeners->second.erase(
            std::remove_if(begin(listeners->second), end(listeners->second), [&](auto& listener) {
                return listener.proc == proc;
            }));
    }
    return noErr;
}

static OSStatus remove_property_listener_with_data(Instance* self,
                                                   AudioUnitPropertyID prop,
                                                   AudioUnitPropertyListenerProc proc,
                                                   void* data)
{
    const auto listeners = self->data->listeners.find(prop);
    if (listeners != self->data->listeners.end()) {
        listeners->second.erase(
            std::remove_if(begin(listeners->second), end(listeners->second), [&](auto& listener) {
                return listener.proc == proc && listener.data == data;
            }));
    }
    return noErr;
}

static OSStatus reset(Instance* instance, AudioUnitScope, AudioUnitElement)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (instance->data->kernel) {
        instance->data->kernel->reset();
    }
    instance->data->next_buffer_events.clear();
    return noErr;
}

static Instance* instance_from_au(AudioUnit unit)
{
    Instance* instance = nullptr;
    UInt32 size = sizeof(instance);
    AudioUnitGetProperty(
        unit, s_secret_instance_property, kAudioUnitScope_Global, 0u, &instance, &size);
    return instance;
}

Kernel_ui_interface Brinicle::plugin_ui_interface_for_audio_unit(AudioUnit unit)
{
    auto instance = instance_from_au(unit);
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    return Kernel_ui_interface {ui_parameter_set_for_kernel(instance->data->kernel),
                                instance->data->plugin_info.parameters,
                                [stream = instance->data->parameter_change_event.first](
                                    std::function<void(uint64_t, float)> listener) -> std::any {
                                    return stream->subscribe(listener);
                                }};
}

// Shared render code.
static void render_internal(Instance* instance, uint32_t num_frames)
{
    auto event_generator = [&,
                            event_iterator = begin(instance->data->next_buffer_events)]() mutable {
        if (event_iterator == instance->data->next_buffer_events.end()) {
            return std::optional<Audio_event> {};
        }
        auto ret = event_iterator->second;
        event_iterator++;
        return std::optional<Audio_event>(std::move(ret));
    };

    instance->data->kernel->sync_from_dsp_thread();

    auto render_channels = instance->data->input_format
        ? std::max(instance->data->input_format->mChannelsPerFrame,
                   instance->data->output_format.mChannelsPerFrame)
        : instance->data->output_format.mChannelsPerFrame;
    auto buffer = Deinterleaved_audio {
        render_channels, num_frames, instance->data->render_pointers.data()};

    instance->data->kernel->process(buffer, std::move(event_generator));

    // update host mirror for scheduled events.
    for (const auto& event : instance->data->next_buffer_events) {
        std::visit(overload {[&](const Parameter_change& change) {
                                 instance->data->host_mirror[change.address] = change.value;
                             },
                             [&](const Ramped_parameter_change& change) {
                                 instance->data->host_mirror[change.address] = change.value;
                             },
                             [](const Midi_message&) {}},
                   event.second);
    }

    instance->data->next_buffer_events.clear();
}

// Update the host mirror - note that this is called after the render callbacks.
static void update_host_mirror(Instance_data* data)
{
    // update the host of any changes.
    for (auto& host_mirror_param : data->host_mirror) {
        auto kernel_version = data->kernel->get_parameter(host_mirror_param.first);
        if (host_mirror_param.second != kernel_version) {
            host_mirror_param.second = kernel_version;
            if (host_mirror_param.first == data->plugin_info.bypass_parameter) {
                notify_listeners(data, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0);
            } else {
                auto audio_unit = data->audio_unit;
                AudioUnitParameterID address = static_cast<unsigned int>(host_mirror_param.first);
                AudioUnitEvent event;

                event.mEventType = kAudioUnitEvent_ParameterValueChange;
                event.mArgument.mParameter.mAudioUnit = audio_unit;
                event.mArgument.mParameter.mParameterID = address;
                event.mArgument.mParameter.mScope = kAudioUnitScope_Global,
                event.mArgument.mParameter.mElement = 0;

                AUEventListenerNotify(NULL, NULL, &event);
            }
        }
    }

    update_latency(data);
}

// This function has a really stupid API.
// All passed-in buffers are OUTPUT pointers.  However, if the caller passes in
// nullptr buffer pointers, we are supposed to fill them in with our own
// buffers.
// Things get quite a bit more complex when this is an effect and it needs
// input.
// In that case, we need to get input from either a "render callback" or a
// "connection".
// Each of these has differing semantics.
//   - For "Render Callbacks" - we are supposed to provide the callback our own
//   buffer to write into.
//   - For "Connections" - we get a buffer from the connection.
static OSStatus render(Instance* instance,
                       AudioUnitRenderActionFlags* action_flags,
                       const AudioTimeStamp* time_stamp,
                       UInt32 bus_number,
                       UInt32 num_frames,
                       AudioBufferList* data)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (data->mNumberBuffers != instance->data->output_format.mChannelsPerFrame) {
        return kAudioUnitErr_InvalidPropertyValue;
    }

    auto output_channels = instance->data->output_format.mChannelsPerFrame;
    if (output_channels > instance->data->render_pointers.size()) {
        return kAudioUnitErr_Uninitialized;
    }

    if (num_frames > instance->data->max_frames_per_slice) {
        return kAudioUnitErr_TooManyFramesToProcess;
    }

    bool caller_buffers_valid = data->mBuffers[0].mData != nullptr;
    uint32_t required_buffer_size = sizeof(float) * num_frames;
    // validate buffers.
    for (decltype(data->mNumberBuffers) i = 0; i < data->mNumberBuffers; ++i) {
        if (caller_buffers_valid && data->mBuffers[i].mDataByteSize < required_buffer_size) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }
        if (caller_buffers_valid && data->mBuffers[i].mNumberChannels != 1) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }

        data->mBuffers[i].mDataByteSize = required_buffer_size;
        data->mBuffers[i].mNumberChannels = 1;
    }

    bool render_buffers_valid = false;
    bool need_to_copy_render_to_output = false;
    auto render_channels = output_channels;

    // We only support one output for now.
    if (bus_number != 0) {
        return kAudioUnitErr_InvalidPropertyValue;
    }

    // Can't do more than max frames
    if (num_frames > instance->data->max_frames_per_slice) {
        return kAudioUnitErr_TooManyFramesToProcess;
    }

    if (instance->data->render_callbacks_dirty) {
        instance->data->render_callbacks = instance->data->pending_render_callbacks;
        instance->data->render_callbacks_dirty = false;
    }

    for (const auto& render_callback : instance->data->render_callbacks) {
        auto flags = *action_flags | kAudioUnitRenderAction_PreRender;
        render_callback.callback(
            render_callback.data, &flags, time_stamp, bus_number, num_frames, data);
    }

    if (instance->data->input_format) {
        auto input_channels = instance->data->input_format->mChannelsPerFrame;
        render_channels = std::max(input_channels, output_channels);

        if (input_channels > instance->data->render_pointers.size()) {
            return kAudioUnitErr_Uninitialized;
        }

        // We take input, so, we need to get input before we render.
        auto input_error = std::visit(
            overload {
                [&](const AURenderCallbackStruct& input_callback) -> OSStatus {
                    AudioBufferList* input_buffer_list = nullptr;

                    // Set up our input buffers - note that if the user passed in
                    // buffers and
                    // they are big enough we can just use those.
                    if (caller_buffers_valid && output_channels >= input_channels) {
                        data->mNumberBuffers = input_channels;
                        input_buffer_list = data;

                        // Render in-place.
                        for (decltype(output_channels) i = 0; i < output_channels; ++i) {
                            instance->data->render_pointers[i] = reinterpret_cast<float*>(
                                data->mBuffers[i].mData);
                        }
                        render_buffers_valid = true;
                    } else {
                        // Otherwise, validate then use our pre-allocated buffers.
                        if (instance->data->input_buffer.buffer_backing.size() < input_channels) {
                            return kAudioUnitErr_TooManyFramesToProcess;
                        }
                        if (instance->data->input_buffer.buffer_backing[0].size() < num_frames) {
                            return kAudioUnitErr_TooManyFramesToProcess;
                        }

                        instance->data->input_buffer_list->mNumberBuffers = input_channels;
                        for (decltype(input_channels) i = 0; i < input_channels; ++i) {
                            instance->data->input_buffer_list->mBuffers[i].mData
                                = instance->data->input_buffer.buffer_backing[i].data();
                            instance->data->input_buffer_list->mBuffers[i].mNumberChannels = 1;
                            instance->data->input_buffer_list->mBuffers[i].mDataByteSize
                                = required_buffer_size;
                        }
                        input_buffer_list = instance->data->input_buffer_list;

                        // Set up output/render - if we provide the buffers, use ours to
                        // avoid a
                        // copy; otherwise use theirs and copy.
                        if (!caller_buffers_valid) {
                            // Note that we always allocate enough input buffer backing to
                            // support
                            // the output channels too.
                            assert(instance->data->input_buffer.buffer_backing.size()
                                   >= output_channels);
                            for (decltype(output_channels) i = 0; i < output_channels; ++i) {
                                data->mBuffers[i].mData
                                    = instance->data->input_buffer.buffer_backing[i].data();
                            }

                            for (decltype(input_channels) i = 0;
                                 i < std::max(input_channels, output_channels);
                                 ++i) {
                                instance->data->render_pointers[i]
                                    = instance->data->input_buffer.buffer_backing[i].data();
                            }
                            render_buffers_valid = true;
                        } else {
                            // Gross out-of-place case.
                            for (decltype(input_channels) i = 0;
                                 i < std::max(input_channels, output_channels);
                                 ++i) {
                                instance->data->render_pointers[i]
                                    = instance->data->input_buffer.buffer_backing[i].data();
                            }
                            render_buffers_valid = true;
                            need_to_copy_render_to_output = true;
                        }
                    }
                    // Get the data.
                    return input_callback.inputProc(input_callback.inputProcRefCon,
                                                    action_flags,
                                                    time_stamp,
                                                    0u,
                                                    num_frames,
                                                    input_buffer_list);
                },
                [](const std::nullptr_t&) -> OSStatus { return kAudioUnitErr_NoConnection; },
                [&](const AudioUnitConnection& connection) -> OSStatus {
                    if (input_channels < output_channels
                        && instance->data->output_buffer.buffer_backing.size() < output_channels) {
                        return kAudioUnitErr_Uninitialized;
                    }

                    // Our connection has to supply the buffers for us :-\, so we have
                    // to set up the input buffers as nullptrs.
                    instance->data->input_buffer_list->mNumberBuffers = input_channels;
                    for (decltype(input_channels) i = 0; i < input_channels; ++i) {
                        instance->data->input_buffer_list->mBuffers[i].mData = nullptr;
                        instance->data->input_buffer_list->mBuffers[i].mNumberChannels = 1u;
                        instance->data->input_buffer_list->mBuffers[i].mDataByteSize
                            = required_buffer_size;
                    }

                    AudioUnitRender(connection.sourceAudioUnit,
                                    action_flags,
                                    time_stamp,
                                    connection.sourceOutputNumber,
                                    num_frames,
                                    instance->data->input_buffer_list);

                    // At this point, we should have valid buffers - Note that if
                    // we're allowed to process in place, we can re-use these for the
                    // output.
                    for (decltype(render_channels) i = 0; i < render_channels; ++i) {
                        instance->data->render_pointers[i] = (i < input_channels)
                            ? reinterpret_cast<float*>(
                                instance->data->input_buffer_list->mBuffers[i].mData)
                            : instance->data->output_buffer.buffer_backing[i].data();
                    }

                    render_buffers_valid = true;

                    if (!caller_buffers_valid && instance->data->process_in_place) {
                        for (decltype(output_channels) i = 0; i < output_channels; ++i) {
                            data->mBuffers[i].mData = instance->data->render_pointers[i];
                        }
                    } else {
                        // Ugh!  Caller passed in buffers or defeated process in place
                        // so we'll have to copy.
                        need_to_copy_render_to_output = true;
                    }
                    return noErr;
                }},
            instance->data->input);
        if (input_error != noErr) {
            return input_error;
        }
    } else {
        // Output-only case.
        if (caller_buffers_valid) {
            for (decltype(output_channels) i = 0; i < output_channels; ++i) {
                instance->data->render_pointers[i] = reinterpret_cast<float*>(
                    data->mBuffers[i].mData);
            }
            render_buffers_valid = true;
        } else {
            if (instance->data->output_buffer.buffer_backing.size() < output_channels) {
                return kAudioUnitErr_Uninitialized;
            }

            for (decltype(output_channels) i = 0; i < output_channels; ++i) {
                instance->data->render_pointers[i]
                    = instance->data->output_buffer.buffer_backing[i].data();
                data->mBuffers[i].mData = instance->data->render_pointers[i];
            }
            render_buffers_valid = true;
        }
    }

    // Double check we've set up the render buffers by now.
    assert(render_buffers_valid);

    // Note we may have fucked with the number of buffers in the caller's buffer
    // list during the input stage; so fix that now.
    data->mNumberBuffers = output_channels;

    render_internal(instance, num_frames);

    // If we rendered out-of-place; go ahead and copy.
    if (need_to_copy_render_to_output) {
        for (decltype(output_channels) i = 0; i < output_channels; ++i) {
            std::copy(instance->data->render_pointers[i],
                      instance->data->render_pointers[i] + num_frames,
                      reinterpret_cast<float*>(data->mBuffers[i].mData));
        }
    }

    if (instance->data->render_callbacks_dirty) {
        instance->data->render_callbacks = instance->data->pending_render_callbacks;
        instance->data->render_callbacks_dirty = false;
    }

    for (const auto& render_callback : instance->data->render_callbacks) {
        auto flags = *action_flags | kAudioUnitRenderAction_PostRender;
        render_callback.callback(
            render_callback.data, &flags, time_stamp, bus_number, num_frames, data);
    }

    update_host_mirror(instance->data.get());

    return noErr;
}

static OSStatus process(Instance* instance,
                        AudioUnitRenderActionFlags*,
                        const AudioTimeStamp*,
                        UInt32 num_frames,
                        AudioBufferList* data)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (!instance->data->kernel) {
        return kAudioUnitErr_Uninitialized;
    }

    if (num_frames > instance->data->max_frames_per_slice) {
        return kAudioUnitErr_TooManyFramesToProcess;
    }

    const auto input_channels = instance->data->input_format
        ? instance->data->input_format->mChannelsPerFrame
        : 0;

    const auto output_channels = instance->data->output_format.mChannelsPerFrame;
    const auto render_channels = std::max(input_channels, output_channels);

    if (data->mNumberBuffers < render_channels) {
        return kAudioUnitErr_InvalidPropertyValue;
    }

    const UInt32 required_byte_size = sizeof(float) * num_frames;
    // We actually need valid buffers.
    for (unsigned int i = 0; i < input_channels; ++i) {
        if (data->mBuffers[i].mDataByteSize < required_byte_size) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }

        if (data->mBuffers[i].mData == nullptr) {
            return kAudioUnitErr_InvalidPropertyValue;
        }

        data->mBuffers[i].mNumberChannels = 1;
        data->mBuffers[i].mDataByteSize = required_byte_size;

        if (instance->data->process_in_place) {
            instance->data->render_pointers[i] = reinterpret_cast<float*>(data->mBuffers[i].mData);
        } else {
            if (instance->data->input_buffer.buffer_backing.size() < render_channels) {
                return kAudioUnitErr_Uninitialized;
            }

            instance->data->render_pointers[i]
                = instance->data->input_buffer.buffer_backing[i].data();
            std::copy(reinterpret_cast<float*>(data->mBuffers[i].mData),
                      reinterpret_cast<float*>(data->mBuffers[i].mData) + num_frames,
                      instance->data->render_pointers[i]);
            data->mBuffers[i].mData = instance->data->render_pointers[i];
        }
    }
    for (auto i = input_channels; i < render_channels; ++i) {
        if (data->mBuffers[i].mDataByteSize < required_byte_size) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }
        data->mBuffers[i].mNumberChannels = 1;
        data->mBuffers[i].mDataByteSize = required_byte_size;
        if (data->mBuffers[i].mData == nullptr || !instance->data->process_in_place) {
            if (instance->data->output_buffer.buffer_backing.size() < render_channels) {
                return kAudioUnitErr_Uninitialized;
            }

            instance->data->render_pointers[i]
                = instance->data->output_buffer.buffer_backing[i].data();
            data->mBuffers[i].mData = instance->data->render_pointers[i];
        } else {
            instance->data->render_pointers[i] = reinterpret_cast<float*>(data->mBuffers[i].mData);
        }
    }

    render_internal(instance, num_frames);

    update_host_mirror(instance->data.get());
    return noErr;
}

static OSStatus get_parameter(Instance* instance,
                              AudioUnitParameterID param,
                              AudioUnitScope scope,
                              AudioUnitElement,
                              AudioUnitParameterValue* value)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (scope != kAudioUnitScope_Global) {
        return kAudioUnitErr_InvalidScope;
    }

    *value = instance->data->host_mirror[param];

    return noErr;
}

static OSStatus set_parameter(Instance* instance,
                              AudioUnitParameterID param,
                              AudioUnitScope scope,
                              AudioUnitElement elem,
                              AudioUnitParameterValue value,
                              UInt32 buffer_offset)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (scope != kAudioUnitScope_Global) {
        return kAudioUnitErr_InvalidScope;
    }

    if (elem != 0) {
        return kAudioUnitErr_InvalidElement;
    }

    if (instance->data->kernel) {
        if (buffer_offset == 0) {
            instance->data->host_mirror[param] = value;
            instance->data->kernel->set_parameter(param, value);
        } else {
            instance->data->next_buffer_events.insert(
                {buffer_offset, Parameter_change {buffer_offset, param, value}});
        }
    }

    update_latency(instance->data.get());
    return noErr;
}

static OSStatus schedule_parameters(Instance* instance,
                                    const AudioUnitParameterEvent* parameter_events,
                                    UInt32 num_parameter_events)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    for (decltype(num_parameter_events) i = 0; i < num_parameter_events; ++i) {
        const auto& parameter_event = parameter_events[i];
        if (parameter_event.eventType == kParameterEvent_Immediate) {
            auto err = set_parameter(instance,
                                     parameter_event.parameter,
                                     parameter_event.scope,
                                     parameter_event.element,
                                     parameter_event.eventValues.immediate.value,
                                     parameter_event.eventValues.immediate.bufferOffset);
            if (err) {
                return err;
            }
        } else if (parameter_event.eventType == kParameterEvent_Ramped) {
            // It's only possible to schedule a ramped parameter change in an
            // initialized kernel.
            if (!instance->data->kernel) {
                return kAudioUnitErr_Uninitialized;
            }

            if (parameter_event.scope != kAudioUnitScope_Global) {
                return kAudioUnitErr_InvalidScope;
            }

            if (parameter_event.element != 0) {
                return kAudioUnitErr_InvalidElement;
            }

            instance->data->next_buffer_events.insert(
                {parameter_event.eventValues.ramp.startBufferOffset,
                 Parameter_change {parameter_event.eventValues.ramp.startBufferOffset,
                                   parameter_event.parameter,
                                   parameter_event.eventValues.ramp.startValue}});

            instance->data->next_buffer_events.insert(
                {parameter_event.eventValues.ramp.startBufferOffset,
                 Ramped_parameter_change {parameter_event.eventValues.ramp.startBufferOffset,
                                          parameter_event.parameter,
                                          parameter_event.eventValues.ramp.endValue,
                                          parameter_event.eventValues.ramp.durationInFrames}});
        } else {
            return kAudioUnitErr_InvalidParameter;
        }
    }
    return noErr;
}

static OSStatus add_render_notify(Instance* instance, AURenderCallback callback, void* data)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    instance->data->pending_render_callbacks.insert(Render_callback {callback, data});
    instance->data->render_callbacks_dirty = true;
    return noErr;
}

static OSStatus remove_render_notify(Instance* instance, AURenderCallback callback, void* data)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    instance->data->pending_render_callbacks.erase(Render_callback {callback, data});
    instance->data->render_callbacks_dirty = true;
    return noErr;
}

static OSStatus
midi_event(Instance* instance, UInt32 status, UInt32 data1, UInt32 data2, UInt32 buffer_offset)
{
    std::lock_guard<decltype(instance->data->host_mutex)> lock(instance->data->host_mutex);

    if (!instance->data->kernel) {
        return kAudioUnitErr_Uninitialized;
    }
    uint8_t cable = 0u;
    uint16_t valid_bytes = 3u;
    instance->data->next_buffer_events.insert(
        {buffer_offset,
         Midi_message {buffer_offset,
                       cable,
                       valid_bytes,
                       std::array<uint8_t, 3> {static_cast<uint8_t>(status),
                                               static_cast<uint8_t>(data1),
                                               static_cast<uint8_t>(data2)}}});

    return noErr;
}

static AudioComponentMethod lookup(SInt16 selector)
{
    switch (selector) {
    case kAudioUnitInitializeSelect:
        return reinterpret_cast<AudioComponentMethod>(initialize);
    case kAudioUnitUninitializeSelect:
        return reinterpret_cast<AudioComponentMethod>(uninitialize);
    case kAudioUnitGetPropertyInfoSelect:
        return reinterpret_cast<AudioComponentMethod>(get_property_info);
    case kAudioUnitGetPropertySelect:
        return reinterpret_cast<AudioComponentMethod>(get_property);
    case kAudioUnitSetPropertySelect:
        return reinterpret_cast<AudioComponentMethod>(set_property);
    case kAudioUnitAddPropertyListenerSelect:
        return reinterpret_cast<AudioComponentMethod>(add_property_listener);
    case kAudioUnitRemovePropertyListenerSelect:
        return reinterpret_cast<AudioComponentMethod>(remove_property_listener);
    case kAudioUnitRemovePropertyListenerWithUserDataSelect:
        return reinterpret_cast<AudioComponentMethod>(remove_property_listener_with_data);
    case kAudioUnitSetParameterSelect:
        return reinterpret_cast<AudioComponentMethod>(set_parameter);
    case kAudioUnitScheduleParametersSelect:
        return reinterpret_cast<AudioComponentMethod>(schedule_parameters);
    case kAudioUnitGetParameterSelect:
        return reinterpret_cast<AudioComponentMethod>(get_parameter);
    case kAudioUnitResetSelect:
        return reinterpret_cast<AudioComponentMethod>(reset);
    case kAudioUnitAddRenderNotifySelect:
        return reinterpret_cast<AudioComponentMethod>(add_render_notify);
    case kAudioUnitRemoveRenderNotifySelect:
        return reinterpret_cast<AudioComponentMethod>(remove_render_notify);
    case kAudioUnitRenderSelect:
        return reinterpret_cast<AudioComponentMethod>(render);
    case kMusicDeviceMIDIEventSelect:
        return reinterpret_cast<AudioComponentMethod>(midi_event);
    case kAudioUnitProcessSelect:
        return reinterpret_cast<AudioComponentMethod>(process);
    }
    return nullptr;
}

void* Brinicle::make_audio_factory()
{
    const auto instance = reinterpret_cast<Instance*>(malloc(sizeof(Instance)));
    instance->interface.Open = open;
    instance->interface.Close = close;
    instance->interface.Lookup = lookup;
    instance->interface.reserved = nullptr;
    instance->data.release();
    return reinterpret_cast<AudioComponentPlugInInterface*>(instance);
}
