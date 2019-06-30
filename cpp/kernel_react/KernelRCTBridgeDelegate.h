#import <Foundation/Foundation.h>

#include "Brinicle/Utilities/Macro_join.h"
#include "ObjC_prefix.h"
#import <React/RCTBridgeDelegate.h>
#import <React/RCTEventEmitter.h>

#define KernelRCTBridgeDelegate MACRO_JOIN(OBJC_PREFIX, _KernelRCTBridgeDelegate)

@interface KernelRCTBridgeDelegate : NSObject <RCTBridgeDelegate>

@property NSURL* url;
@property NSArray<id<RCTBridgeModule>>* extraModules;

@end
