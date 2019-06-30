#pragma once

#import <Foundation/Foundation.h>

#include "TargetConditionals.h"

#include "Brinicle/React/Kernel_ui_interface.h"
#include "Brinicle/Utilities/Macro_join.h"
#include "ObjC_prefix.h"
#import <React/RCTEventEmitter.h>
#include <any>
#include <map>
#include <memory>
#include <optional>

#define KernelRCTManager MACRO_JOIN(OBJC_PREFIX, _KernelRCTManager)

/// Acts as a bridge from the audio unit to React Native.
///
/// Does not talk to the AU directly, rather through the Plugin_ui_interface.  In this way, it can
/// handle both v2 and v3 audio units uniformly.
@interface KernelRCTManager : RCTEventEmitter {
    Brinicle::Kernel_ui_interface _ui_interface;
    std::optional<std::any> _listener_token;
    std::map<std::string, uint64_t> _audioUnitIdentifierToAddressMap;
    std::map<uint64_t, std::string> _addressToAudioUnitIdentifierMap;
    std::map<uint64_t, std::unique_ptr<Brinicle::Grabbed_parameter>> _grabs;
    NSDictionary<NSString*, id>* _parameterInfo;
}

- (id)initWithPluginUIInterface:(Brinicle::Kernel_ui_interface)interface;

@end
