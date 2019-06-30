#include "Brinicle/React/KernelRCTManager.h"
#include "Brinicle/Utilities/Overload.h"
#import <React/RCTEventDispatcher.h>
#include <array>
#include <memory>
#include <optional>
#include <variant>
#include <vector>

using namespace Brinicle;

static NSString* displayUnit(AudioUnitParameterUnit unit)
{
    switch (unit) {
    case kAudioUnitParameterUnit_Percent:
        return @"percent";
    case kAudioUnitParameterUnit_Seconds:
        return @"seconds";
    case kAudioUnitParameterUnit_SampleFrames:
        return @"sample frames";
    case kAudioUnitParameterUnit_Phase:
        return @"phase";
    case kAudioUnitParameterUnit_Rate:
        return @"rate";
    case kAudioUnitParameterUnit_Hertz:
        return @"hertz";
    case kAudioUnitParameterUnit_Cents:
        return @"cents";
    case kAudioUnitParameterUnit_RelativeSemiTones:
        return @"relative semitones";
    case kAudioUnitParameterUnit_MIDINoteNumber:
        return @"midi note number";
    case kAudioUnitParameterUnit_MIDIController:
        return @"midi controller";
    case kAudioUnitParameterUnit_Decibels:
        return @"decibels";
    case kAudioUnitParameterUnit_LinearGain:
        return @"linear gain";
    case kAudioUnitParameterUnit_Degrees:
        return @"degrees";
    case kAudioUnitParameterUnit_EqualPowerCrossfade:
        return @"equal power crossfade";
    case kAudioUnitParameterUnit_MixerFaderCurve1:
        return @"mixer fader curve 1";
    case kAudioUnitParameterUnit_Pan:
        return @"pan";
    case kAudioUnitParameterUnit_Meters:
        return @"meters";
    case kAudioUnitParameterUnit_AbsoluteCents:
        return @"absolute cents";
    case kAudioUnitParameterUnit_Octaves:
        return @"octaves";
    case kAudioUnitParameterUnit_BPM:
        return @"bpm";
    case kAudioUnitParameterUnit_Beats:
        return @"beats";
    case kAudioUnitParameterUnit_Milliseconds:
        return @"milliseconds";
    case kAudioUnitParameterUnit_Ratio:
        return @"ratio";
    case kAudioUnitParameterUnit_Generic:
        return @"";
    case kAudioUnitParameterUnit_Indexed:
    case kAudioUnitParameterUnit_CustomUnit:
    case kAudioUnitParameterUnit_Boolean:
    default:
        assert(false);
        return @"";
    }
}

static NSDictionary* create_info_dict_for_param(const Parameter_info& info)
{
    auto identifier_string = [NSString stringWithUTF8String:info.identifier_string.c_str()];
    auto name = [NSString stringWithUTF8String:info.name.c_str()];
    return std::visit(
        overload {[&](const Numeric_parameter_info& numeric) {
                      auto unit = std::visit(
                          overload {[&](AudioUnitParameterUnit unit) { return displayUnit(unit); },
                                    [&](const std::string& custom) {
                                        return [NSString stringWithUTF8String:custom.c_str()];
                                    }},
                          numeric.unit);
                      return @ {
                          @"identifier" : identifier_string,
                          @"type" : @"numeric",
                          @"displayName" : name,
                          @"min" : [NSNumber numberWithFloat:numeric.min],
                          @"max" : [NSNumber numberWithFloat:numeric.max],
                          @"unit" : unit
                      };
                  },
                  [&](const Indexed_parameter_info& indexed) {
                      auto value_strings = [NSMutableArray new];
                      for (const auto& value_string : indexed.value_strings) {
                          [value_strings
                              addObject:[NSString stringWithUTF8String:value_string.c_str()]];
                      }
                      return @ {
                          @"identifier" : identifier_string,
                          @"type" : @"indexed",
                          @"displayName" : name,
                          @"values" : (NSArray*)value_strings,
                      };
                  }},
        info.info);
}

@implementation KernelRCTManager

+ (NSString*)moduleName
{
    return @"KernelRCTManager";
}

RCT_EXPORT_METHOD(sendAllParams)
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        auto params = get_param_state(*_ui_interface.parameter_set, _ui_interface.parameters);
        for (auto& param : params) {
            [self sendEventWithName:@"AURCTParamChanged"
                               body:@ {
                                   @"identifier" : [NSString
                                       stringWithUTF8String:
                                           _addressToAudioUnitIdentifierMap[param.first].c_str()],
                                   @"value" : [NSNumber numberWithFloat:param.second]
                               }];
        }
    });
}

RCT_EXPORT_METHOD(grabParameter
                  : (nonnull NSString*)name resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)__unused reject)
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        std::string identifier([name UTF8String]);
        auto address = _audioUnitIdentifierToAddressMap[identifier];

        uint64_t gesture_identifier = _grabs.size() == 0 ? 0u : _grabs.rbegin()->first + 1;

        _grabs[gesture_identifier] = _ui_interface.parameter_set->grab_parameter(address);
        resolve([NSNumber numberWithUnsignedLongLong:gesture_identifier]);
    });
}

RCT_EXPORT_METHOD(moveGrabbedParameter
                  : (nonnull NSNumber*)grab withValue
                  : (nonnull NSNumber*)value resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        auto grab_identifier = [grab unsignedLongLongValue];
        if (_grabs.count(grab_identifier) == 0u) {
            reject(@"Bad grab", @"Bad grab", nil);
        } else {
            _grabs[grab_identifier]->set_parameter([value floatValue]);
            resolve(nil);
        }
    });
}

RCT_EXPORT_METHOD(ungrabParameter
                  : (nonnull NSNumber*)grab resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        auto grab_identifier = [grab unsignedLongLongValue];
        if (_grabs.count(grab_identifier) == 0u) {
            reject(@"Bad grab", @"Bad grab", nil);
        } else {
            _grabs.erase(grab_identifier);
            resolve(nil);
        }
    });
}

RCT_EXPORT_METHOD(setParameter : (nonnull NSString*)name value : (float)value)
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        std::string identifier([name UTF8String]);
        _ui_interface.parameter_set->grab_parameter(_audioUnitIdentifierToAddressMap[identifier])
            ->set_parameter(value);
    });
}

- (id)initWithPluginUIInterface:(Kernel_ui_interface)interface
{
    _ui_interface = std::move(interface);

    const auto& parameters = _ui_interface.parameters;
    auto parameterInfo = [NSMutableDictionary new];
    for (const auto& parameter : parameters) {
        _audioUnitIdentifierToAddressMap[parameter.identifier_string] = parameter.address;
        _addressToAudioUnitIdentifierMap[parameter.address] = parameter.identifier_string;

        [parameterInfo
            setObject:create_info_dict_for_param(parameter)
               forKey:[NSString stringWithUTF8String:parameter.identifier_string.c_str()]];
    }

    _parameterInfo = parameterInfo;
    return self;
}

- (NSArray<NSString*>*)supportedEvents
{
    return @[ @"AURCTParamChanged" ];
}

- (void)startObserving
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        __weak auto weakSelf = self;
        _listener_token = _ui_interface.subscribe_to_parameter_changes(
            [weakSelf](uint64_t address, float value) {
                __strong auto strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                [strongSelf
                    sendEventWithName:@"AURCTParamChanged"
                                 body:@ {
                                     @"identifier" : [NSString
                                         stringWithUTF8String:
                                             strongSelf->_addressToAudioUnitIdentifierMap[address]
                                                 .c_str()],
                                     @"value" : [NSNumber numberWithFloat:value],
                                 }];
            });
    });
}

- (void)stopObserving
{
    dispatch_async(dispatch_get_main_queue(), ^() {
        _listener_token = std::nullopt;
    });
}

- (NSDictionary<NSString*, id>*)constantsToExport
{
    return @{@"parameterInfo" : _parameterInfo};
}

@end
