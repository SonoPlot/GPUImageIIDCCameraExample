#import <Cocoa/Cocoa.h>
#import <GPUImage/GPUImage.h>
#import "GPUImageIIDCCamera.h"

typedef enum  { UNIBRAIN, FLEA2G, BLACKFLY} SPCameraType;

@interface GPUImageIIDCCameraWindowController : NSWindowController
{
    GPUImageAVCamera *videoCamera;
    GPUImageOutput<GPUImageInput> *filter;
    GPUImageMovieWriter *movieWriter;
    
    GPUImageIIDCCamera *iidcCamera;
}

@property (weak) IBOutlet GPUImageView *videoView;
@property(readonly) SPCameraType cameraType;
@property (weak) IBOutlet NSSlider *saturationSlider;

- (IBAction)SaturationLevelSlider:(id)sender;

@end
