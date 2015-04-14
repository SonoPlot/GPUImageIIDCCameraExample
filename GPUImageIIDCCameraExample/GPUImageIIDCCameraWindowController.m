#import "GPUImageIIDCCameraWindowController.h"

@interface GPUImageIIDCCameraWindowController ()

@end

@implementation GPUImageIIDCCameraWindowController

- (void)windowDidLoad {
    
    [super windowDidLoad];
    
    // Default GPUImage stuff to be replaced by the IIDC Camera stuff. -JKC
//    [self runGPUImageCameraCode];
    [self setupCameraCode];
    
}

#pragma MARK - GPUImageIIDCCamera Code
- (void)setupCameraCode {
    
    iidcCamera = [[GPUImageIIDCCamera alloc] init];
    
    
    NSError *error = nil;
    [iidcCamera connectToCamera:&error];
    
    BOOL cameraFound = false;
    
    unsigned int currentVideoMode;
    
    for (currentVideoMode = 0; currentVideoMode < iidcCamera.supportedVideoModes.num; currentVideoMode++)
    {        
        if (iidcCamera.supportedVideoModes.modes[currentVideoMode] == DC1394_VIDEO_MODE_1280x960_YUV422)
        {
            _cameraType = FLEA2G;
            cameraFound = true;
        }
        
        if (iidcCamera.supportedVideoModes.modes[currentVideoMode] == DC1394_VIDEO_MODE_FORMAT7_0)
        {
            if (_cameraType != FLEA2G)
            {
                _cameraType = BLACKFLY;
                cameraFound = true;
            }
        }
    }
    
    NSLog(@"The camera was found: %hhd", cameraFound);
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
