// This is a specific subclass for the USB 3.0 Blackfly camera from Point Grey Research

#import "GPUImageIIDCCamera.h"

@interface GPUImageBlackflyCamera : GPUImageIIDCCamera

- (void)turnOnLEDLight;
- (void)turnOffLEDLight;

@end
