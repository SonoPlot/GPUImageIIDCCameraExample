#import "GPUImageIIDCCameraWindowController.h"

@interface GPUImageIIDCCameraWindowController ()

@end

@implementation GPUImageIIDCCameraWindowController

- (void)windowDidLoad {
    
    [super windowDidLoad];
    
    // Default GPUImage stuff to be replaced by the IIDC Camera stuff. -JKC
//    [self runGPUImageCameraCode];
    [self setupCameraCode];
    
    NSError *error;
    [iidcCamera readAllSettingLimits:&error];
    [self cameraSettingsTests];
}

#pragma MARK - GPUImageIIDCCamera Code
- (void)setupCameraCode {
    
    iidcCamera = [[GPUImageIIDCCamera alloc] init];

    NSError *error = nil;
    [iidcCamera connectToCamera:&error];
    
    BOOL cameraFound = [iidcCamera videoModeIsSupported:DC1394_VIDEO_MODE_FORMAT7_0];
    
    NSLog(@"The camera was found: %hhd", cameraFound);
}

- (void)cameraSettingsTests {
    
    NSInteger brightness = iidcCamera.brightness;
    NSInteger saturation = iidcCamera.saturation;
    NSInteger whiteBalanceU = iidcCamera.whiteBalanceU;
    NSInteger whiteBalanceV = iidcCamera.whiteBalanceV;
    
    // Output the current settings on the camera
    NSLog(@"Current Brightness Setting: %ld", iidcCamera.brightness);
    NSLog(@"Current Saturation Setting: %ld", iidcCamera.saturation);
    NSLog(@"Current White Balance U Setting: %ld", iidcCamera.whiteBalanceU);
    NSLog(@"Current White Balance V Setting: %ld", iidcCamera.whiteBalanceV);
    
    // Reset all the things!
    [iidcCamera setBrightness:20];
    [iidcCamera setSaturation:420];
    [iidcCamera setWhiteBalance:550 whiteBalanceV:810];
    
    // Output the new current settings on the camera
    NSLog(@"Changed Brightness Setting: %ld", iidcCamera.brightness);
    NSLog(@"Changed Saturation Setting: %ld", iidcCamera.saturation);
    NSLog(@"Changed White Balance U Setting: %ld", iidcCamera.whiteBalanceU);
    NSLog(@"Changed White Balance V Setting: %ld", iidcCamera.whiteBalanceV);
    
    // Reset all the things!
    [iidcCamera setBrightness:brightness];
    [iidcCamera setSaturation:saturation];
    [iidcCamera setWhiteBalance:(uint32_t)whiteBalanceU whiteBalanceV:(uint32_t)whiteBalanceV];
    
    // Output the new current settings on the camera
    NSLog(@"Original Brightness Setting: %ld", iidcCamera.brightness);
    NSLog(@"Original Saturation Setting: %ld", iidcCamera.saturation);
    NSLog(@"Original White Balance U Setting: %ld", iidcCamera.whiteBalanceU);
    NSLog(@"Original White Balance V Setting: %ld", iidcCamera.whiteBalanceV);
}


- (IBAction)imageCapture:(id)sender {
    
    if (iidcCamera.isCaptureInProgress == NO) {
        self.imageCaptureButton.title = @"Stop Image Capture";
        iidcCamera.isCaptureInProgress = YES;
        [iidcCamera startCameraCapture];
    } else {
        self.imageCaptureButton.title = @"Start Image Capture";
        iidcCamera.isCaptureInProgress = NO;
        [iidcCamera stopCameraCapture];
    }
    
}

#pragma MARK - GPUImage Code for Debugging Purposes
- (void)runGPUImageCameraCode {
    
    NSLog(@"Start runGPUImageCameraCode");
    
    // Instantiate video camera
    videoCamera = [[GPUImageAVCamera alloc] initWithSessionPreset:AVCaptureSessionPreset640x480 cameraDevice:nil];
    videoCamera.runBenchmark = YES;
    
    // Create filter and add it to target
    filter = [[GPUImageSepiaFilter alloc] init];
    [videoCamera addTarget:filter];
    
    // Save video to desktop
    NSError *error = nil;
    
    NSURL *pathToDesktop = [[NSFileManager defaultManager] URLForDirectory:NSDesktopDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    NSURL *pathToMovieFile = [pathToDesktop URLByAppendingPathComponent:@"movie.mp4"];
    NSString *filePathString = [pathToMovieFile absoluteString];
    NSString *filePathSubstring = [filePathString substringFromIndex:7];
    unlink([filePathSubstring UTF8String]);
    
    // Instantiate movie writer and add targets
    movieWriter = [[GPUImageMovieWriter alloc] initWithMovieURL:pathToMovieFile size:CGSizeMake(640.0, 480.0)];
    movieWriter.encodingLiveVideo = YES;
    
    self.videoView.fillMode = kGPUImageFillModePreserveAspectRatio;
    [filter addTarget:movieWriter];
    [filter addTarget:self.videoView];
    
    // Start capturing
    [videoCamera startCameraCapture];
    
    double delayToStartRecording = 0.5;
    dispatch_time_t startTime = dispatch_time(DISPATCH_TIME_NOW, delayToStartRecording * NSEC_PER_SEC);
    dispatch_after(startTime, dispatch_get_main_queue(), ^(void){
        NSLog(@"Start recording");
        
        videoCamera.audioEncodingTarget = movieWriter;
        [movieWriter startRecording];
        
        double delayInSeconds = 10.0;
        dispatch_time_t stopTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(stopTime, dispatch_get_main_queue(), ^(void){
            
            [filter removeTarget:movieWriter];
            videoCamera.audioEncodingTarget = nil;
            [movieWriter finishRecording];
            NSLog(@"Movie completed");
            
        });
    });
}

@end
