#import "AppDelegate.h"
#import <GPUImage/GPUImage.h>

@interface AppDelegate ()

@property (weak) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    iidcCameraWindowController = [[GPUImageIIDCCameraWindowController alloc] initWithWindowNibName:@"GPUImageIIDCCameraWindowController"];
    [iidcCameraWindowController showWindow:self];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

@end
