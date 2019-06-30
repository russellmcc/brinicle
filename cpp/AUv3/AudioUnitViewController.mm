#import "Brinicle/AUv3/AudioUnitViewController.h"
#import "Brinicle/React/KernelRCTBridgeDelegate.h"
#import "Brinicle/React/KernelRCTManager.h"
#include "Brinicle/Utilities/Macro_join.h"
#include "ObjC_prefix.h"
#import "TargetConditionals.h"
#import <React/RCTRootView.h>

using namespace Brinicle;

#define MyRCTBridge MACRO_JOIN(OBJC_PREFIX, _RCTBridge)

@interface MyRCTBridge : RCTBridge
@property (nonatomic, strong) id<RCTBridgeDelegate> strongDelegate;
@end

@implementation MyRCTBridge
@end

@implementation AudioUnitViewController

- (AudioUnitImpl*)audioUnit
{
    return _audioUnit;
}

- (void)setAudioUnit:(AudioUnitImpl*)audioUnit
{
    _audioUnit = audioUnit;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self connect];
    });
}

- (void)connect
{
    if (!(_audioUnit && [self isViewLoaded])) {
        return;
    }

    KernelRCTBridgeDelegate* moduleInitialiser = [KernelRCTBridgeDelegate new];
#ifndef NDEBUG
#ifdef TARGET_OS_MAC
    moduleInitialiser.url = [NSURL URLWithString:@"http://localhost:8081/"
                                                 @"index.macos.bundle?platform=macos"];
#else
    moduleInitialiser.url = [NSURL URLWithString:@"http://localhost:8081/"
                                                 @"index.ios.bundle?platform=ios"];
#endif
#else
    moduleInitialiser.url = [[NSBundle bundleForClass:[AudioUnitViewController class]]
        URLForResource:@"bundle/main"
         withExtension:@"jsbundle"];
#endif

    moduleInitialiser.extraModules = @[ [[KernelRCTManager alloc]
        initWithPluginUIInterface:plugin_ui_interface_for_audio_unit(_audioUnit)] ];
    auto bridge = [[MyRCTBridge alloc] initWithDelegate:moduleInitialiser launchOptions:nil];
    bridge.strongDelegate = moduleInitialiser;

    _rootView = [[RCTRootView alloc] initWithBridge:bridge
                                         moduleName:@"AUView"
                                  initialProperties:@{}];
    _rootView.frame = self.view.frame;
    [self.view addSubview:_rootView];
    self.view.autoresizesSubviews = YES;
    _rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setPreferredContentSize:self.view.frame.size];
    [self connect];
}

@end
