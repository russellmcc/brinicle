#import "Brinicle/AUv3/AudioUnitImpl.h"
#import "Brinicle/Glue/Make_kernel_factory.h"
#include "Brinicle/Thread/Wrapped_kernel.h"
#include "Brinicle/Utilities/Overload.h"
#include <algorithm>

#import "BufferedAudioBus.h"
#import <AVFoundation/AVFoundation.h>

using namespace Brinicle;

// This facade allows the kernel to be swapped out under-the-hood
namespace {
class Facade_grabbed_parameter : public Grabbed_parameter {
public:
    Facade_grabbed_parameter(std::unique_ptr<Grabbed_parameter> real_grabbed_, uint64_t identifier_)
        : hook(std::make_shared<Hook>(this))
        , real_grabbed(std::move(real_grabbed_))
        , identifier(identifier_)
    {
    }
    void set_parameter(float value) override { real_grabbed->set_parameter(value); }

    void switch_set(UI_parameter_set* new_set)
    {
        if (new_set) {
            real_grabbed = new_set->grab_parameter(identifier);
        } else {
            real_grabbed.reset();
        }
    }

    struct Hook {
        Hook(Facade_grabbed_parameter* param_) : param(param_) {}
        Facade_grabbed_parameter* param;
    };

    std::shared_ptr<Hook> hook;
    std::unique_ptr<Grabbed_parameter> real_grabbed;
    uint64_t identifier;
};

class Facade_UI_set : public UI_parameter_set {
public:
    Facade_UI_set(std::shared_ptr<UI_parameter_set> real_set_) : real_set(std::move(real_set_)) {}

    std::unique_ptr<Grabbed_parameter> grab_parameter(uint64_t identifier) override
    {
        clear_dead_hooks();
        auto ret = std::make_unique<Facade_grabbed_parameter>(real_set->grab_parameter(identifier),
                                                              identifier);
        hooks.emplace_back(ret->hook);
        return ret;
    }

    float get_parameter(uint64_t identifier) const override
    {
        return real_set->get_parameter(identifier);
    }

    void switch_set(std::shared_ptr<UI_parameter_set> new_set)
    {
        clear_dead_hooks();
        for (auto& hook : hooks) {
            const auto strong_hook = hook.lock();
            strong_hook->param->switch_set(new_set.get());
        }
        real_set = new_set;
    }

    void clear_dead_hooks()
    {
        hooks.erase(
            std::remove_if(begin(hooks), end(hooks), [](const auto& hook) { return !hook.lock(); }),
            end(hooks));
    }

    std::shared_ptr<UI_parameter_set> real_set;
    std::vector<std::weak_ptr<Facade_grabbed_parameter::Hook>> hooks;
};
}

@interface AudioUnitImpl ()

@property AUAudioUnitBus* outputBus;
@property AUAudioUnitBus* inputBus;
@property AUAudioUnitBusArray* outputBusArray;
@property AUAudioUnitBusArray* inputBusArray;

@property (nonatomic, readwrite) AUParameterTree* parameterTree;

@end

static constexpr size_t MAX_CHANNEL_COUNT = 10;

static NSArray<NSString*>* convertArrayString(const std::vector<std::string>& strings)
{
    std::vector<NSString*> ns_strings(strings.size());
    std::transform(begin(strings), end(strings), begin(ns_strings), [](const std::string& string) {
        return [NSString stringWithUTF8String:string.c_str()];
    });
    return [NSArray arrayWithObjects:ns_strings.data() count:ns_strings.size()];
}

static NSArray<NSNumber*>* convertNumberArray(const std::vector<uint64_t>& numbers)
{
    if (numbers.size() == 0)
        return nil;

    std::vector<NSNumber*> ns_numbers(numbers.size());
    std::transform(begin(numbers), end(numbers), begin(ns_numbers), [](uint64_t number) {
        return [NSNumber numberWithUnsignedLongLong:number];
    });
    return [NSArray arrayWithObjects:ns_numbers.data() count:ns_numbers.size()];
}

@implementation AudioUnitImpl {
@public
    std::unique_ptr<KernelFactory> _plugin;
    std::shared_ptr<Wrapped_kernel> _kernel;

    KernelFactory::Type _type;
    std::shared_ptr<Facade_UI_set> _ui_set;
@private
    NSArray<NSNumber*>* _channelCapabilities;
    BufferedOutputBus _output_bus_buffer;
    BufferedInputBus _input_bus_buffer;
    NSTimer* _ui_sync_timer;
}

@synthesize channelCapabilities = _channelCapabilities;
@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError**)outError
{
    self = [super initWithComponentDescription:componentDescription options:options error:outError];

    if (self == nil) {
        return nil;
    }

    _plugin = make_kernel_factory();
    const auto info = _plugin->info();
    _type = info.type;

    AVAudioFormat* initial_input_format = nullptr;
    AVAudioFormat* initial_output_format = nullptr;
    AVAudioChannelCount max_output_channels = 2;
    AVAudioChannelCount max_input_channels = 0;

    if (info.type == KernelFactory::Type::effect) {
        assert(info.allowed_channel_configurations.size() > 0);

        auto get_channels = overload {
            [](const Any_channel_count&) -> AVAudioChannelCount { return 2; },
            [](const Channel_count& count) -> AVAudioChannelCount {
                return static_cast<AVAudioChannelCount>(count.channels);
            }};

        const auto default_output_count = std::visit(
            get_channels, info.allowed_channel_configurations[0].output_channels);
        const auto default_input_count = std::visit(
            get_channels, info.allowed_channel_configurations[0].input_channels);
        initial_output_format = [[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:44100.
                                    channels:default_output_count];
        initial_input_format = [[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:44100.
                                    channels:default_input_count];
        const auto get_max = [&](const auto& io) {
            return std::visit(get_channels,
                              io(*std::max_element(begin(info.allowed_channel_configurations),
                                                   end(info.allowed_channel_configurations),
                                                   [&](const auto& lhs, const auto& rhs) {
                                                       return std::visit(get_channels, io(lhs))
                                                           < std::visit(get_channels, io(rhs));
                                                   })));
        };

        max_output_channels = get_max([](const auto& io) { return io.output_channels; });
        max_input_channels = get_max([](const auto& io) { return io.input_channels; });

        auto channel_caps = [NSMutableArray new];
        auto get_channel_cap = overload {[](const Any_channel_count&) -> NSNumber* { return @-1; },
                                         [](const Channel_count& count) -> NSNumber* {
                                             return [NSNumber
                                                 numberWithUnsignedLongLong:count.channels];
                                         }};

        for (const auto& channel_config : info.allowed_channel_configurations) {
            [channel_caps addObject:std::visit(get_channel_cap, channel_config.input_channels)];
            [channel_caps addObject:std::visit(get_channel_cap, channel_config.output_channels)];
        }

        _channelCapabilities = channel_caps;

    } else {
        initial_output_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.
                                                                               channels:2];
    }

    // Ask for parameter list to build param tree
    const auto& params = info.parameters;

    // Create a DSP kernel to handle the signal processing.
    auto internal_kernel = _plugin->make_kernel(
        initial_input_format ? initial_input_format.channelCount : 0,
        initial_output_format.channelCount,
        initial_output_format.sampleRate);
    apply_defaults(*internal_kernel, params);
    _kernel = std::make_shared<Wrapped_kernel>(
        std::move(internal_kernel), params, std::make_shared<Wrapped_kernel::Host_interface>());
    _ui_set = std::make_shared<Facade_UI_set>(ui_parameter_set_for_kernel(_kernel));
    // convert parameters into au-parameters
    std::vector<AUParameter*> auparams(params.size());
    std::transform(begin(params), end(params), begin(auparams), [](const auto& param) {
        AUValue min;
        AUValue max;
        AUValue default_value;
        AudioUnitParameterUnit unit;
        NSString* custom_unit = nil;
        NSArray<NSString*>* value_strings = nil;
        visit(overload {[&](const Numeric_parameter_info& info) {
                            min = info.min;
                            max = info.max;
                            unit = visit(overload {[](AudioUnitParameterUnit unit) { return unit; },
                                                   [&custom_unit](const std::string& custom) {
                                                       custom_unit = [NSString
                                                           stringWithUTF8String:custom.c_str()];
                                                       return kAudioUnitParameterUnit_CustomUnit;
                                                   }},
                                         info.unit);
                            value_strings = nil;
                            default_value = info.default_value;
                        },
                        [&](const Indexed_parameter_info& info) {
                            min = 0.;
                            max = static_cast<float>(info.value_strings.size() - 0.01);
                            unit = kAudioUnitParameterUnit_Indexed;
                            value_strings = convertArrayString(info.value_strings);
                            default_value = info.default_value;
                        }},
              param.info);

        NSArray<NSNumber*>* dependent_params = convertNumberArray(param.dependent_parameters);

        AUParameter* auParam = [AUParameterTree
            createParameterWithIdentifier:[NSString
                                              stringWithUTF8String:param.identifier_string.c_str()]
                                     name:[NSString stringWithUTF8String:param.name.c_str()]
                                  address:param.address
                                      min:min
                                      max:max
                                     unit:unit
                                 unitName:custom_unit
                                    flags:param.flags
                             valueStrings:value_strings
                      dependentParameters:dependent_params];
        auParam.value = default_value;
        return auParam;
    });

    // Create the parameter tree.
    _parameterTree = [AUParameterTree
        createTreeWithChildren:[NSArray arrayWithObjects:auparams.data() count:auparams.size()]];

    // Create the output bus.
    _output_bus_buffer.init(initial_output_format, max_output_channels);
    _outputBus = _output_bus_buffer.bus;
    // Create the input and output bus arrays.
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                             busType:AUAudioUnitBusTypeOutput
                                                              busses:@[ _outputBus ]];
    if (_type == KernelFactory::Type::effect) {
        _input_bus_buffer.init(initial_input_format, max_input_channels);
        _inputBus = _input_bus_buffer.bus;
        _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                                busType:AUAudioUnitBusTypeInput
                                                                 busses:@[ _inputBus ]];
    }

    // Make a local pointer to the kernel to avoid capturing self.
    __block auto kernel = &_kernel;

    // implementorValueObserver is called when a parameter changes value.
    _parameterTree.implementorValueObserver = ^(AUParameter* param, AUValue value) {
        (*kernel)->ui_parameter_set().grab_parameter(param.address)->set_parameter(value);
    };

    // implementorValueProvider is called when the value needs to be refreshed.
    _parameterTree.implementorValueProvider = ^(AUParameter* param) {
        return (*kernel)->ui_parameter_set().get_parameter(param.address);
    };

    __weak auto weakSelf = self;
    _ui_sync_timer = [NSTimer
        scheduledTimerWithTimeInterval:0.05
                               repeats:YES
                                 block:^(NSTimer*) {
                                     auto* _Nullable strongSelf = weakSelf;
                                     strongSelf->_kernel->sync_from_ui_thread([&](uint64_t address,
                                                                                  float value) {
                                         [[strongSelf->_parameterTree parameterWithAddress:address]
                                             setValue:value];
                                     });
                                 }];

    self.maximumFramesToRender = 8096;

    return self;
}

- (void)dealloc
{
    // Deallocate resources as required.
}

#pragma mark - AUAudioUnit (Overrides)

- (AUAudioUnitBusArray*)outputBusses
{
    return _outputBusArray;
}

- (AUAudioUnitBusArray*)inputBusses
{
    return (_type == KernelFactory::Type::effect) ? _inputBusArray : [super inputBusses];
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError**)outError
{
    if (![super allocateRenderResourcesAndReturnError:outError]) {
        return NO;
    }

    _output_bus_buffer.allocateRenderResources(self.maximumFramesToRender);

    if (_type == KernelFactory::Type::effect) {
        _input_bus_buffer.allocateRenderResources(self.maximumFramesToRender);
    }

    const auto params = _plugin->info().parameters;
    const auto state = get_param_state(*_kernel, params);
    _kernel = std::make_unique<Wrapped_kernel>(
        _plugin->make_kernel(self.inputBusses[0].format.channelCount,
                             self.outputBus.format.channelCount,
                             self.outputBus.format.sampleRate),
        params,
        std::make_shared<Wrapped_kernel::Host_interface>());
    set_param_state(*_kernel, state, params);
    _ui_set->switch_set(ui_parameter_set_for_kernel(_kernel));

    return YES;
}

- (void)deallocateRenderResources
{
    _output_bus_buffer.deallocateRenderResources();

    [super deallocateRenderResources];
}

#pragma mark - AUAudioUnit (AUAudioUnitImplementation)

- (AUInternalRenderBlock)internalRenderBlock
{
    /*
          Capture in locals to avoid ObjC member lookups. If "self" is captured
  in
  render, we're doing it wrong.
  */
    __block auto kernel = &_kernel;

    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags* actionFlags,
                              const AudioTimeStamp* timestamp,
                              AVAudioFrameCount frameCount,
                              NSInteger,
                              AudioBufferList* outputData,
                              const AURenderEvent* realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {
        _output_bus_buffer.prepareOutputBufferList(outputData, frameCount);

        Deinterleaved_audio ioAudio;
        ioAudio.frame_count = frameCount;
        std::array<float*, MAX_CHANNEL_COUNT> channels;

        if (_type == KernelFactory::Type::effect) {
            _input_bus_buffer.pullInput(actionFlags, timestamp, frameCount, 0, pullInputBlock);
            ioAudio.channel_count = std::max(_input_bus_buffer.bus.format.channelCount,
                                             outputData->mNumberBuffers);
            for (size_t channel = 0; channel < _input_bus_buffer.bus.format.channelCount;
                 ++channel) {
                channels[channel] = reinterpret_cast<float*>(
                    _input_bus_buffer.mutableAudioBufferList->mBuffers[channel].mData);
            }
            for (size_t channel = _input_bus_buffer.bus.format.channelCount;
                 channel < outputData->mNumberBuffers;
                 ++channel) {
                channels[channel] = reinterpret_cast<float*>(outputData->mBuffers[channel].mData);
            }

        } else {
            ioAudio.channel_count = outputData->mNumberBuffers;
            for (size_t channel = 0; channel < ioAudio.channel_count; ++channel) {
                channels[channel] = reinterpret_cast<float*>(outputData->mBuffers[channel].mData);
            }
        }

        ioAudio.data = channels.data();

        assert(timestamp->mFlags | kAudioTimeStampSampleTimeValid);

        auto fnNextEvent = [realtimeEventListHead,
                            &timestamp]() mutable -> std::optional<Audio_event> {
            if (realtimeEventListHead == nullptr)
                return std::nullopt;

            // Since we can't handle every type of event yet, loop until
            // we find the next event we can handle, or we're out of events.
            while (realtimeEventListHead) {
                auto lastEvent = realtimeEventListHead;
                int64_t bufferOffsetTime = lastEvent->head.eventSampleTime - timestamp->mSampleTime;
                realtimeEventListHead = realtimeEventListHead->head.next;
                switch (lastEvent->head.eventType) {
                case AURenderEventParameter: {
                    const auto& paramEvent = lastEvent->parameter;
                    return Audio_event {Parameter_change {
                        bufferOffsetTime, paramEvent.parameterAddress, paramEvent.value}};
                } break;
                case AURenderEventParameterRamp: {
                    const auto& paramEvent = lastEvent->parameter;
                    return Audio_event {
                        Ramped_parameter_change {bufferOffsetTime,
                                                 paramEvent.parameterAddress,
                                                 paramEvent.value,
                                                 paramEvent.rampDurationSampleFrames}};
                } break;
                case AURenderEventMIDI: {
                    const auto& midiEvent = lastEvent->MIDI;
                    Midi_message retval;
                    retval.buffer_offset_time = bufferOffsetTime;
                    retval.cable = midiEvent.cable;
                    retval.valid_bytes = midiEvent.length;
                    std::copy(std::begin(midiEvent.data),
                              std::end(midiEvent.data),
                              std::begin(retval.data));
                    return Audio_event {std::move(retval)};
                } break;
                default:
                    break;
                }
            }

            return std::nullopt;
        };

        (*kernel)->sync_from_dsp_thread();
        (*kernel)->process(ioAudio, std::move(fnNextEvent));

        if (_type == KernelFactory::Type::effect) {
            const auto copy_channels = std::min(outputData->mNumberBuffers,
                                                _input_bus_buffer.bus.format.channelCount);
            for (size_t channel = 0; channel < copy_channels; ++channel) {
                const auto in_channel = reinterpret_cast<float*>(
                    _input_bus_buffer.mutableAudioBufferList->mBuffers[channel].mData);
                const auto out_channel = reinterpret_cast<float*>(
                    outputData->mBuffers[channel].mData);
                std::copy(in_channel, in_channel + frameCount, out_channel);
            }
        }

        return noErr;
    };
}

@end

Kernel_ui_interface Brinicle::plugin_ui_interface_for_audio_unit(AudioUnitImpl* unit)
{
    return Kernel_ui_interface {
        unit->_ui_set,
        unit->_plugin->info().parameters,
        [unit = unit]([[maybe_unused]] std::function<void(uint64_t, float)> listener) -> std::any {
            return [[unit parameterTree]
                tokenByAddingParameterObserver:^(AUParameterAddress address, AUValue value) {
                    listener(address, value);
                }];
        }};
}
