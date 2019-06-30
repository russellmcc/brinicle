#import "ViewController.h"
#import "AppDelegate.h"

#import "Brinicle/AUv3/AudioUnitImpl.h"
#import "Brinicle/AUv3/AudioUnitViewController.h"
#import "$PROJ_NAME$TestApp-Swift.h"
#import <CoreAudioKit/AUViewController.h>

@interface ViewController () {
    IBOutlet NSButton* playButton;

    AudioUnitViewController* auV3ViewController;

    SimplePlayEngine* playEngine;
}
- (IBAction)togglePlay:(id)sender;

@property (weak) IBOutlet NSView* containerView;
@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self embedPlugInView];

    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_MusicEffect;
    desc.componentSubType = '$AUTYPE$';
    desc.componentManufacturer = '$MANU$';
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    [AUAudioUnit registerSubclass:AudioUnitImpl.class
           asComponentDescription:desc
                             name:@"$MANU$: Local $AUTYPE$"
                          version:UINT32_MAX];

    playEngine = [[SimplePlayEngine alloc] initWithComponentType:desc.componentType
                                         componentsFoundCallback:nil];
    [playEngine selectAudioUnitWithComponentDescription2:desc
                                       completionHandler:^{
                                           [self connectParametersToControls];
                                       }];
}

- (void)viewDidDisappear
{
    AppDelegate* delegate = [[NSApplication sharedApplication] delegate];

    if (delegate.isQuitting) {
        playEngine = nil;
        auV3ViewController = nil;
    }

    [super viewDidDisappear];
}

- (void)embedPlugInView
{
    auV3ViewController = [[AudioUnitViewController alloc]
        initWithNibName:@MACRO_STRING(AudioUnitViewController)
                 bundle:[NSBundle bundleForClass:[AudioUnitViewController class]]];

    NSView* pluginView = auV3ViewController.view;
    pluginView.frame = _containerView.bounds;

    [_containerView addSubview:pluginView];

    pluginView.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray* constraints = [NSLayoutConstraint
        constraintsWithVisualFormat:@"H:|-[pluginView]-|"
                            options:0
                            metrics:nil
                              views:NSDictionaryOfVariableBindings(pluginView)];
    [_containerView addConstraints:constraints];

    constraints = [NSLayoutConstraint
        constraintsWithVisualFormat:@"V:|-[pluginView]-|"
                            options:0
                            metrics:nil
                              views:NSDictionaryOfVariableBindings(pluginView)];
    [_containerView addConstraints:constraints];
}

- (void)connectParametersToControls
{
    auV3ViewController.audioUnit = (AudioUnitImpl*)playEngine.testAudioUnit;
}

- (IBAction)togglePlay:(id)__unused sender
{
    BOOL isPlaying = [playEngine togglePlay];

    [playButton setTitle:isPlaying ? @"Stop" : @"Play"];
}

@end
