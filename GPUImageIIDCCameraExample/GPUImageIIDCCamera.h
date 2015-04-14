#import <Foundation/Foundation.h>
#import <GPUImage/GPUImage.h>
#import <dc1394/dc1394.h>

/*
 This class will need to:
 - Connect to the IIDC camera
 - Deal with the default setting
 - Capture a frame to be processed by GPUImage
 - Do the color conversion
 - Use a ring buffer to get the frames
 - Try to avoid using notifications. Try to use callbacks or delegates.
*/

// Why are some of these instance variables and why are some properties? -JKC

// Have to expose some things:
// Frame Rate/FPS

// These are functions
void uyvy411_2vuy422(const unsigned char *the411Frame, unsigned char *the422Frame, const unsigned int width, const unsigned int height, float *passbackLuminance);
void yuv422_2vuy422(const unsigned char *theYUVFrame, unsigned char *the422Frame, const unsigned int width, const unsigned int height, float *passbackLuminance);

extern NSString *const GPUImageCameraErrorDomain;

// Does this class subclass NSObject because it needs to be separate from GPUImage for licensing reasons?? -JKC
@interface GPUImageIIDCCamera : GPUImageOutput
{
    NSInteger numberOfCameraToUse;
    NSInteger sequentialMissedCameraFrames;
    BOOL frameGrabTimedOutOnce;
    id cameraDisconnectionObserver;
    
    // Camera settings
    NSInteger previousGain, previousExposure;
    float currentLuminance;
    NSUInteger frameIntervalCounter;
    
    // libdc1394 variables for the firewire control
    uint32_t numCameras;
    char *device_name;
    dc1394_t * d;
    dc1394featureset_t features;
}

@property(readwrite) BOOL isCaptureInProgress;
@property(readwrite, nonatomic) BOOL isConnectedToCamera;

@property(readwrite, nonatomic) CGFloat luminanceSetPoint;
@property(readwrite, nonatomic) CGSize frameSize;

// libdc1394 properties
// Need to figure out if these should be readwrite, readonly, nonatomic, etc... -JKC
@property(readwrite) dc1394framerate_t fps;
@property(readwrite) dc1394video_mode_t res;
@property(readonly) dc1394video_modes_t supportedVideoModes;
@property(readwrite) dc1394speed_t filmSpeed;
@property(readwrite) dc1394camera_t *camera;
@property(readwrite) dc1394operation_mode_t operationMode;


// Need to figure out how to consolidate/reconcile this stuff with the Camera Setting Types. -JKC
@property(readwrite, nonatomic) NSInteger brightnessMin, brightnessMax, exposureMin, exposureMax, sharpnessMin, sharpnessMax, whiteBalanceMin, whiteBalanceMax, saturationMin, saturationMax, gammaMin, gammaMax, shutterMin, shutterMax, gainMin, gainMax;
@property(readwrite, nonatomic) NSInteger brightness, exposure, sharpness, whiteBalanceU, whiteBalanceV, saturation, gamma, shutter, gain;


// Camera interface
- (BOOL)connectToCamera:(NSError **)error;
- (BOOL)readAllSettingLimits:(NSError **)error;
- (void)startCameraCapture:(NSError **)error;
- (BOOL)grabNewVideoFrame:(NSError **)error;

// Error handling methods
- (NSError *)errorForCameraDisconnection;

@end


