#import "AppDelegate.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)__unused aNotification
{
}

- (void)applicationWillTerminate:(NSNotification*)__unused aNotification
{
    _quitting = YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)__unused sender
{
    return YES;
}

@end
