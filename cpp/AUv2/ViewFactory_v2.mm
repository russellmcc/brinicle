#import <AppKit/AppKit.h>
#import <AudioToolbox/AUCocoaUIView.h>
#import <AudioToolbox/AudioToolbox.h>
#import <React/RCTRootView.h>

#include "Brinicle/AUv2/ViewFactory_v2.h"
#include "Brinicle/AUv2/v2impl.h"
#import "Brinicle/React/KernelRCTBridgeDelegate.h"
#import "Brinicle/React/KernelRCTManager.h"
#include "Brinicle/Utilities/Macro_join.h"
#include "ObjC_prefix.h"
#import "TargetConditionals.h"

using namespace Brinicle;

#define AudioUnitViewController_v2 MACRO_JOIN(OBJC_PREFIX, _AudioUnitViewController_v2)

@interface AudioUnitViewController_v2 : NSViewController {
    AudioUnit _audioUnit;
    NSView* _rootView;
}
- (void)setAudioUnit:(AudioUnit)audioUnit;
@end

#define RCTBridge_v2 MACRO_JOIN(OBJC_PREFIX, _RCTBridge_v2)

@interface RCTBridge_v2 : RCTBridge
@property (nonatomic, strong) id<RCTBridgeDelegate> strongDelegate;
@end

@implementation RCTBridge_v2
@end

@implementation AudioUnitViewController_v2

- (void)setAudioUnit:(AudioUnit)audioUnit
{
    _audioUnit = audioUnit;
    [self connect];
}

- (void)connect
{
    if (!(_audioUnit && [self isViewLoaded])) {
        return;
    }

    KernelRCTBridgeDelegate* moduleInitialiser = [KernelRCTBridgeDelegate new];

#ifndef NDEBUG
    moduleInitialiser.url = [NSURL URLWithString:@"http://localhost:8081/"
                                                 @"index.macos.bundle?platform=macos"];
#else
    moduleInitialiser.url = [[NSBundle bundleForClass:[AudioUnitViewController_v2 class]]
        URLForResource:@"bundle/main"
         withExtension:@"jsbundle"];
#endif
    moduleInitialiser.extraModules = @[ [[KernelRCTManager alloc]
        initWithPluginUIInterface:plugin_ui_interface_for_audio_unit(_audioUnit)] ];
    auto bridge = [[RCTBridge_v2 alloc] initWithDelegate:moduleInitialiser launchOptions:nil];
    bridge.strongDelegate = moduleInitialiser;

    _rootView = [[RCTRootView alloc] initWithBridge:bridge
                                         moduleName:@"AUView"
                                  initialProperties:@{}];
    _rootView.frame = self.view.frame;
    [self.view addSubview:_rootView];
    self.view.autoresizesSubviews = YES;
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

- (void)loadView
{
    [super loadView];
    [self setPreferredContentSize:self.view.frame.size];
    [self connect];
}

@end

#define ViewFactory_v2 MACRO_JOIN(OBJC_PREFIX, _ViewFactory_v2)

@interface ViewFactory_v2 : NSObject <AUCocoaUIBase> {
}
@end
;

@implementation ViewFactory_v2
- (unsigned)interfaceVersion
{
    return 0u;
}

#define AudioUnitViewController MACRO_JOIN(OBJC_PREFIX, _AudioUnitViewController)

- (NSView* __nullable)uiViewForAudioUnit:(AudioUnit)audioUnit
                                withSize:(NSSize)__unused inPreferredSize
{
    AudioUnitViewController_v2* viewController = [[AudioUnitViewController_v2 alloc]
        initWithNibName:@MACRO_STRING(AudioUnitViewController)
                 bundle:[NSBundle bundleForClass:[AudioUnitViewController_v2 class]]];
    [viewController setAudioUnit:audioUnit];
    [viewController loadView];
    return viewController.view;
}

@end

CFURLRef copy_view_factory_bundle_url()
{
    auto bundle = [NSBundle bundleForClass:[ViewFactory_v2 class]];
    return reinterpret_cast<CFURLRef>(CFBridgingRetain([bundle bundleURL]));
}

CFStringRef copy_view_factory_class_name()
{
    return reinterpret_cast<CFStringRef>(
        CFBridgingRetain(NSStringFromClass([ViewFactory_v2 class])));
}
