#import "Brinicle/React/KernelRCTBridgeDelegate.h"

@implementation KernelRCTBridgeDelegate

- (NSURL*)sourceURLForBridge:(RCTBridge*)__unused bridge
{
    return self.url;
}

- (NSArray<id<RCTBridgeModule>>*)extraModulesForBridge:(RCTBridge*)__unused bridge
{
    return self.extraModules;
}

@end
