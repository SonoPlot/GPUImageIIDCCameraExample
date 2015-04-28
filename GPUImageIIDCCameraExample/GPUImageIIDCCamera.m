#import "GPUImageIIDCCamera.h"
#import <GPUImage/GPUImage.h>
#import <Accelerate/Accelerate.h>

NSString *const kGPUImageYUV422ColorspaceConversionFragmentShaderString = SHADER_STRING
(
 varying vec2 textureCoordinate;
 
 uniform sampler2DRect inputTexture;
 
 void main()
 {
     // Output: R = Y1, G = U0, B = Y0, A = V0
//     vec4 processedYUVBlock = texture2DRect(videoFrame, gl_TexCoord[0].st).abgr;
     vec4 processedYUVBlock = texture2DRect(inputTexture, textureCoordinate.xy).abgr;
     processedYUVBlock = ((processedYUVBlock - vec4(0.0, 0.5, 0.0, 0.5)) * vec4(0.9375 ,0.9219, 0.9375, 0.9219)) + vec4(0.0625, 0.5, 0.0625, 0.5);
     
     gl_FragColor = processedYUVBlock;
 }
 );


#define MAX_PORTS   4
#define MAX_CAMERAS 8
#define NUM_BUFFERS 50
#define FILTERFACTORFORSMOOTHINGCAMERAVALUES 1.0f

#define LOOPSWITHOUTFRAMEBEFOREERROR 30

#pragma mark -
#pragma mark Frame grabbing

@interface GPUImageIIDCCamera ()
{
    GLProgram *yuvConversionProgram;
    GLint yuvConversionPositionAttribute, yuvConversionTextureCoordinateAttribute;
    GLint yuvConversionInputTextureUniform;
    
    GLuint yuvUploadTexture;
    
    CMTime currentFrameTime;
    NSTimeInterval actualTimeOfLastUpdate;
    
    GPUImageRotationMode outputRotation, internalRotation;
}

// Frame processing and upload
- (void)processVideoFrame:(unsigned char *)videoFrame;
- (void)updateCurrentFrameTime;
- (void)initializeUploadTextureForSize:(CGSize)textureSize frameData:(unsigned char *)videoFrame;

@end

// Standard C function for remapping 4:1:1 (UYVY) image to 4:2:2 (2VUY)
void uyvy411_2vuy422(const unsigned char *the411Frame, unsigned char *the422Frame, const unsigned int width, const unsigned int height)
{
    int i =0, j=0;
    unsigned int numPixels = width * height;
    register unsigned int y0, y1, y2, y3, u, v;
    unsigned int totalPasses = numPixels * 3/2;
    
    unsigned int luminanceTotal = 0;
    unsigned int luminanceSamples = 0;
    
    while (i < totalPasses )
    {
        // Read in the IYU1 (Y411) colorspace from the firewire frames
        // U Y0 Y1 V Y2 Y3
        u = the411Frame[i++]-128;
        y0 = the411Frame[i++];
        y1 = the411Frame[i++];
        v = the411Frame[i++]-128;
        y2 = the411Frame[i++];
        y3 = the411Frame[i++];
        
        luminanceTotal += y0 + y1 + y2 + y3;
        luminanceSamples +=4 ;
        
        // Remap the values to 2VUY (YUYS?) (Y422) colorspace for OpenGL
        // Y0 U Y1 V Y2 U Y3 V
        
        // IIDC cameras are full-range y=[0..255], u,v=[-127..+127], where display is "video range" (y=[16..240], u,v=[16..236])
        
        /* Old, unflipped version*/
        the422Frame[j++] = (((y0 * 240) >> 8) + 16);
        the422Frame[j++] = (((u * 236) >> 8) + 128);
        the422Frame[j++] = (((y1 * 240) >> 8) + 16);
        the422Frame[j++] = (((v * 236) >> 8) + 128);
        the422Frame[j++] = (((y2 * 240) >> 8) + 16);
        the422Frame[j++] = (((u * 236) >> 8) + 128);
        the422Frame[j++] = (((y3 * 240) >> 8) + 16);
        the422Frame[j++] = (((v * 236) >> 8) + 128);
    }
}

#define SHOULDFLIPFRAME 1

void yuv422_2vuy422(const unsigned char *theYUVFrame, unsigned char *the422Frame, const unsigned int width, const unsigned int height)
{
    memcpy(the422Frame, theYUVFrame, width * height * 2);
}

NSString *const GPUImageCameraErrorDomain = @"com.sunsetlakesoftware.GPUImage.GPUImageIIDCCamera";

@implementation GPUImageIIDCCamera

#pragma mark -
#pragma mark Initialization and teardown
- (id)init;
{
    if (!(self = [super init]))
        return nil;
    
    cameraDispatchQueue = dispatch_queue_create("CameraDispatchQueue", NULL);
    
    // Assuming these are the initial values. Need to figure out how to coordinate these with the camera-specific values. -JKC
    _isCaptureInProgress= NO;
    _isConnectedToCamera = NO;
    numberOfCameraToUse = 0;
    _frameSize = CGSizeMake(640, 480);
    sequentialMissedCameraFrames = 0;
    frameGrabTimedOutOnce = NO;
    currentLuminance = 0.0;
    _luminanceSetPoint = 0.5;
    previousGain = 0.5;
    previousExposure = 0.0;
    frameIntervalCounter = 0;
    
    runSynchronouslyOnVideoProcessingQueue(^{
        
        [GPUImageContext useImageProcessingContext];
        yuvConversionProgram = [[GPUImageContext sharedImageProcessingContext] programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageYUV422ColorspaceConversionFragmentShaderString];
        
        if (!yuvConversionProgram.initialized)
        {
            [yuvConversionProgram addAttribute:@"position"];
            [yuvConversionProgram addAttribute:@"inputTextureCoordinate"];
            
            if (![yuvConversionProgram link])
            {
                NSString *progLog = [yuvConversionProgram programLog];
                NSLog(@"Program link log: %@", progLog);
                NSString *fragLog = [yuvConversionProgram fragmentShaderLog];
                NSLog(@"Fragment shader compile log: %@", fragLog);
                NSString *vertLog = [yuvConversionProgram vertexShaderLog];
                NSLog(@"Vertex shader compile log: %@", vertLog);
                yuvConversionProgram = nil;
                NSAssert(NO, @"Filter shader link failed");
            }
        }
        
        yuvConversionPositionAttribute = [yuvConversionProgram attributeIndex:@"position"];
        yuvConversionTextureCoordinateAttribute = [yuvConversionProgram attributeIndex:@"inputTextureCoordinate"];
        yuvConversionInputTextureUniform = [yuvConversionProgram uniformIndex:@"inputTexture"];
        
        [GPUImageContext setActiveShaderProgram:yuvConversionProgram];
        
        glEnableVertexAttribArray(yuvConversionPositionAttribute);
        glEnableVertexAttribArray(yuvConversionTextureCoordinateAttribute);
        
        glEnable(GL_TEXTURE_RECTANGLE_EXT);

    });

    
    return self;
}

- (void)dealloc;
{
    // Shut down run loop, if necessary
    
}

#pragma mark -
#pragma mark Camera interface
- (BOOL)connectToCamera:(NSError **)error;
{
    dc1394speed_t speed;
    
    dc1394camera_list_t * list;
    
    dc1394_log_register_handler(DC1394_LOG_WARNING, NULL, NULL);
    
    if (d != NULL)
    {
        dc1394_free (d);
        d = NULL;
    }
    
    if (_camera != NULL)
    {
        dc1394_camera_free (_camera);
        _camera = NULL;
    }
    
    d = dc1394_new();                                                     /* Initialize libdc1394 */
    
    dc1394_camera_enumerate (d, &list);                                /* Find cameras */
    
    if (list->num == 0)
    {
        NSLog(@"No cameras found");
        if (error != NULL)
        {
            *error = [self errorForCameraDisconnection];
        }
        
        dc1394_camera_free_list (list);
        dc1394_free (d);
        d = NULL;
        return NO;
    }
    
    _camera = dc1394_camera_new (d, list->ids[0].guid);                     /* Work with first camera */
    
    if (_camera == NULL)
    {
        NSLog(@"No cameras setup");
        
        if (error != NULL)
        {
            *error = [self errorForCameraDisconnection];
        }
        dc1394_camera_free_list (list);
        dc1394_free (d);
        d = NULL;
        return NO;
    }
    dc1394_camera_free_list (list);
    
    // Turn camera on
    dc1394_camera_set_power(_camera,DC1394_ON);
    
    if (dc1394_video_get_iso_speed(_camera, &speed) != DC1394_SUCCESS)
    {
        NSLog(@"Camera: Error in getting ISO speed");
        if (error != NULL)
        {
            *error = [self errorForCameraDisconnection];
        }
        return NO;
    }
    
    if (![self readAllSettingLimits:error])
    {
        return NO;	
    }
    
    dc1394_video_get_supported_modes(_camera, &_supportedVideoModes);
    self.isConnectedToCamera = YES;

    return YES;
}

- (void)startCameraCapture;
{
    frameGrabTimedOutOnce = NO;
    sequentialMissedCameraFrames = 0;

    if (cameraFrameCallbackThread == nil)
    {
        [self performSelectorInBackground:@selector(threadForActivationOfCamera) withObject:nil];
    }
    else
    {
        [self performSelector:@selector(threadForActivationOfCamera) onThread:cameraFrameCallbackThread withObject:nil waitUntilDone:NO];
    }
}

- (void)stopCameraCapture;
{
    if (dc1394_video_set_transmission(_camera,DC1394_OFF) != DC1394_SUCCESS)
    {
        NSLog(@"Error in setting transmission on");
    }
    dc1394_capture_stop(_camera);
}

- (BOOL)videoModeIsSupported:(dc1394video_mode_t)mode;
{
    unsigned int currentVideoMode;
    BOOL modeFound = NO;
    
    for (currentVideoMode = 0; currentVideoMode < _supportedVideoModes.num; currentVideoMode++)
    {
        NSLog(@"Current Video Mode: %u", _supportedVideoModes.modes[currentVideoMode]);
        
        if (_supportedVideoModes.modes[currentVideoMode] == mode)
        {
            modeFound = YES;
        }
    }
    
    return modeFound;
}

- (void)threadForActivationOfCamera;
{
    cameraShouldPoll = YES;
    dc1394_capture_set_callback(_camera, cameraFrameReadyCallback, (__bridge void *)(self));
    
    if (dc1394_capture_setup(_camera, NUM_BUFFERS, DC1394_CAPTURE_FLAGS_DEFAULT) != DC1394_SUCCESS)
    {
        NSLog(@"Error in capture setup");
    }
    
    /*have the camera start sending us data*/
    
    frameGrabTimedOutOnce = NO;
    sequentialMissedCameraFrames = 0;
    
    if (dc1394_video_set_transmission(_camera,DC1394_ON) != DC1394_SUCCESS)
    {
        NSLog(@"Error in setting transmission on");
    }
 
    if (cameraFrameCallbackThread == nil)
    {
        cameraFrameCallbackThread = [NSThread currentThread];
        
        cameraFrameCallbackRunLoop = [NSRunLoop currentRunLoop];
        do {
            [cameraFrameCallbackRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        } while (cameraShouldPoll);

//        cameraFrameCallbackRunLoop = [NSRunLoop currentRunLoop];
//        [cameraFrameCallbackRunLoop run];
    }
}

static void cameraFrameReadyCallback(dc1394camera_t *camera, void * data)
{
    //	dc1394video_frame_t * frame;
    NSLog(@"New frame available");
    //	frame = dc1394_capture_dequeue_dma (c, DC1394_VIDEO1394_POLL);
    //	err = dc1394_capture_dequeue(camera, DC1394_CAPTURE_POLICY_POLL, &frame);
    
    //	if (frame) {
    //		/* do something with the data here */
    //
    //		dc1394_capture_enqueue_dma (c, frame);
    //	}
}

- (BOOL)disconnectFromIIDCCamera;
{
    //    if (_isRecordingInProgress)
    //    {
    //        //		[self stopRecordingVideo];
    //    }
    
    //    [firewireCommunicationQueue cancelAllOperations];
    
    if (_isConnectedToCamera)
    {
        //        [firewireCommunicationQueue waitUntilAllOperationsAreFinished];
        self.isConnectedToCamera = NO;
        
        // There was conditional logic needed for turning off the LED for the USB 3.0 Blackfly
        
        dc1394_video_set_transmission(_camera, DC1394_OFF);
        dc1394_capture_stop(_camera);
        dc1394_camera_set_power(_camera,DC1394_OFF);
        dc1394_camera_free (_camera);
        _camera = NULL;
        dc1394_free (d);
        d = NULL;
    }
    return YES;
}

#pragma mark -
#pragma mark Frame processing and upload

#define INITIALFRAMESTOIGNOREFORBENCHMARK 5

- (void)processVideoFrame:(unsigned char *)videoFrame;
{
    // Assume a YUV422 frame as input
    
//    if (capturePaused)
//    {
//        return;
//    }
    
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    
    [GPUImageContext useImageProcessingContext];

    // Upload to YUV texture via direct memory access
    GLfloat yuvImageHeight = (_frameSize.width * _frameSize.height * 2) / (_frameSize.width * 4);
    glViewport(0, 0, (GLfloat)_frameSize.width, yuvImageHeight);

    glActiveTexture(GL_TEXTURE3);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, yuvUploadTexture);

    glTexSubImage2D (GL_TEXTURE_RECTANGLE_EXT, 0, 0, 0, _frameSize.width, yuvImageHeight, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, videoFrame);

    // Perform colorspace conversion in shader
    [self convertYUVToRGBOutput];

    // Bind output framebuffer for result
    
    [self updateCurrentFrameTime];
    
    [self updateTargetsForVideoCameraUsingCacheTextureAtWidth:_frameSize.width height:_frameSize.height time:currentFrameTime];
    
    if (_runBenchmark)
    {
        numberOfFramesCaptured++;
        if (numberOfFramesCaptured > INITIALFRAMESTOIGNOREFORBENCHMARK)
        {
            CFAbsoluteTime currentBenchmarkTime = (CFAbsoluteTimeGetCurrent() - startTime);
            totalFrameTimeDuringCapture += currentBenchmarkTime;
            NSLog(@"Average frame time : %f ms", [self averageFrameDurationDuringCapture]);
            NSLog(@"Current frame time : %f ms", 1000.0 * currentBenchmarkTime);
        }
    }

}

- (void)convertYUVToRGBOutput;
{
    [GPUImageContext setActiveShaderProgram:yuvConversionProgram];
    
    // TODO: Add output image rotation to this
    
    outputFramebuffer = [[GPUImageContext sharedFramebufferCache] fetchFramebufferForSize:_frameSize textureOptions:self.outputTextureOptions onlyTexture:NO];
    [outputFramebuffer activateFramebuffer];
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    GLfloat yuvImageHeight = (_frameSize.width * _frameSize.height * 2) / (_frameSize.width * 4);
    
    const GLfloat yuvConversionCoordinates[] = {
        0.0, 0.0,
        _frameSize.width, 0.0,
        0.0, yuvImageHeight,
        _frameSize.width, yuvImageHeight
    };

    
    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_2D, yuvUploadTexture);
    glUniform1i(yuvConversionInputTextureUniform, 4);
    
    glVertexAttribPointer(yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, yuvConversionCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}


- (void)updateTargetsForVideoCameraUsingCacheTextureAtWidth:(int)bufferWidth height:(int)bufferHeight time:(CMTime)currentTime;
{
    // First, update all the framebuffers in the targets
    for (id<GPUImageInput> currentTarget in targets)
    {
        if ([currentTarget enabled])
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates)
            {
                [currentTarget setInputRotation:outputRotation atIndex:textureIndexOfTarget];
                [currentTarget setInputSize:CGSizeMake(bufferWidth, bufferHeight) atIndex:textureIndexOfTarget];
                
                [currentTarget setCurrentlyReceivingMonochromeInput:NO];
                [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
            }
            else
            {
                [currentTarget setInputRotation:outputRotation atIndex:textureIndexOfTarget];
                [currentTarget setInputFramebuffer:outputFramebuffer atIndex:textureIndexOfTarget];
            }
        }
    }
    
    // Then release our hold on the local framebuffer to send it back to the cache as soon as it's no longer needed
    [outputFramebuffer unlock];
    
    // Finally, trigger rendering as needed
    for (id<GPUImageInput> currentTarget in targets)
    {
        if ([currentTarget enabled])
        {
            NSInteger indexOfObject = [targets indexOfObject:currentTarget];
            NSInteger textureIndexOfTarget = [[targetTextureIndices objectAtIndex:indexOfObject] integerValue];
            
            if (currentTarget != self.targetToIgnoreForUpdates)
            {
                [currentTarget newFrameReadyAtTime:currentTime atIndex:textureIndexOfTarget];
            }
        }
    }
}

- (void)initializeUploadTextureForSize:(CGSize)textureSize frameData:(unsigned char *)videoFrame;
{
    glActiveTexture(GL_TEXTURE3);
    glEnable(GL_TEXTURE_RECTANGLE_EXT);
    glGenTextures(1, &yuvUploadTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, yuvUploadTexture);
    glTextureRangeAPPLE(GL_TEXTURE_RECTANGLE_EXT, textureSize.width * textureSize.height * 2, videoFrame);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_SHARED_APPLE);
    
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    
    //	glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE); // This reduces performance on read, for some reason
    //	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, textureSize.width, (textureSize.width * textureSize.height * 2) / (textureSize.width * 4), 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, videoFrame);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, 0);
}

- (CGFloat)averageFrameDurationDuringCapture;
{
    return (totalFrameTimeDuringCapture / (CGFloat)(numberOfFramesCaptured - INITIALFRAMESTOIGNOREFORBENCHMARK)) * 1000.0;
}

- (void)updateCurrentFrameTime;
{
    if(CMTIME_IS_INVALID(currentFrameTime))
    {
        currentFrameTime = CMTimeMakeWithSeconds(0, 600);
        actualTimeOfLastUpdate = [NSDate timeIntervalSinceReferenceDate];
    }
    else
    {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval diff = now - actualTimeOfLastUpdate;
        currentFrameTime = CMTimeAdd(currentFrameTime, CMTimeMakeWithSeconds(diff, 600));
        actualTimeOfLastUpdate = now;
    }
}

#pragma mark -
#pragma mark Settings

// Do the camera setup for things like frame rate and size
// Deal with large enum of video formats
// Deal with the possibility of Format 7

- (BOOL)readAllSettingLimits:(NSError **)error;
{
    if(dc1394_feature_get_all(_camera, &features) != DC1394_SUCCESS)
    {
        NSLog(@"Failed on reading limits");
        if (error != NULL)
        {
            *error = [self errorForCameraDisconnection];
        }
        return NO;
    }
    else
    {
        uint32_t newBrightnessMin, newBrightnessMax, newExposureMin, newExposureMax, newSharpnessMin, newSharpnessMax, newWhiteBalanceMin, newWhiteBalanceMax, newSaturationMin, newSaturationMax, newGammaMin, newGammaMax, newShutterMin, newShutterMax, newGainMin, newGainMax;
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_BRIGHTNESS, &newBrightnessMin, &newBrightnessMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_EXPOSURE, &newExposureMin, &newExposureMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_SHARPNESS, &newSharpnessMin, &newSharpnessMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_WHITE_BALANCE, &newWhiteBalanceMin, &newWhiteBalanceMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_SATURATION, &newSaturationMin, &newSaturationMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_GAMMA, &newGammaMin, &newGammaMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_SHUTTER, &newShutterMin, &newShutterMax);
        dc1394_feature_get_boundaries(_camera, DC1394_FEATURE_GAIN, &newGainMin, &newGainMax);
        
        // Settings that were specialized in the previous code. -JKC
        self.gainMin = newGainMin;
        self.gainMax = newGainMax;
        self.brightnessMin = newBrightnessMin;
        self.brightnessMax = newBrightnessMax;
        self.exposureMin = newExposureMin;
        self.exposureMax = newExposureMax;
        
        // Settings that were generic to each camera used. -JKC
        self.sharpnessMin = newSharpnessMin;
        self.sharpnessMax = newSharpnessMax;
        self.whiteBalanceMin = newWhiteBalanceMin;
        self.whiteBalanceMax = newWhiteBalanceMax;
        self.saturationMin = newSaturationMin;
        self.saturationMax = newSaturationMax;
        self.gammaMin = newGammaMin;
        self.gammaMax = newGammaMax;
        
        /*
        NSLog(@"newGainMin: %u", newGainMin);
        NSLog(@"newGainMax: %u", newGainMax);
        NSLog(@"newBrightnessMin: %u", newBrightnessMin);
        NSLog(@"newBrightnessMax: %u", newBrightnessMax);
        NSLog(@"newExposureMin: %u", newExposureMin);
        NSLog(@"newExposureMax: %u", newExposureMax);
        
        NSLog(@"newSharpnessMin: %u", newSharpnessMin);
        NSLog(@"newSharpnessMax: %u", newSharpnessMax);
        NSLog(@"newWhiteBalanceMin: %u", newWhiteBalanceMin);
        NSLog(@"newWhiteBalanceMax: %u", newWhiteBalanceMax);
        NSLog(@"newSaturationMin: %u", newSaturationMin);
        NSLog(@"newSaturationMax: %u", newSaturationMax);
        NSLog(@"newGammaMin: %u", newGammaMin);
        NSLog(@"newGammaMax: %u", newGammaMax);
        */
    }	
    
    return YES;
}

#pragma mark -
#pragma mark Error handling methods

- (NSError *)errorForCameraDisconnection;
{
    NSString *errorDescription, *recoverySuggestion;
    NSArray *recoveryOptions;
    
    errorDescription = NSLocalizedString(@"The CCD camera is not connected.", @"");
    recoverySuggestion = NSLocalizedString(@"Check the Firewire cable connections between the CCD camera and the control computer.  Unplug and reconnect the cables, if necessary, to resume the video feed.", @"");
    recoveryOptions = [NSArray arrayWithObjects:NSLocalizedString(@"OK", @""), nil];
    
    NSDictionary *errorProperties = [NSDictionary dictionaryWithObjectsAndKeys:
                                     errorDescription, NSLocalizedDescriptionKey,
                                     recoverySuggestion, NSLocalizedRecoverySuggestionErrorKey,
                                     recoveryOptions, NSLocalizedRecoveryOptionsErrorKey,
                                     self, NSRecoveryAttempterErrorKey,
                                     nil];
    return [NSError errorWithDomain:GPUImageCameraErrorDomain code:0 userInfo:errorProperties];
    
}

- (BOOL)attemptRecoveryFromError:(NSError *)error optionIndex:(NSUInteger)recoveryOptionIndex
{
    // This is a placeholder, in case we need error handling of different types for the camera
    return YES;
}


#pragma mark -
#pragma mark Accessor methods

- (void)setBrightness:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_BRIGHTNESS, (uint32_t)newValue);
    });
}

- (NSInteger)brightness
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_BRIGHTNESS, &currentValue);
    });
    
    return currentValue;
}


- (void)setExposure:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_EXPOSURE, (uint32_t)newValue);
    });
}

- (NSInteger)exposure
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_EXPOSURE, &currentValue);
    });
    
    return currentValue;
}


- (void)setShutter:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_SHUTTER, (uint32_t)newValue);
    });
}

- (NSInteger)shutter
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_SHUTTER, &currentValue);
    });
    
    return currentValue;
}


- (void)setSharpness:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_SHARPNESS, (uint32_t)newValue);
    });
}

- (NSInteger)sharpness
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_SHARPNESS, &currentValue);
    });
    
    return currentValue;
}


- (void)setSaturation:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_SATURATION, (uint32_t)newValue);
    });
}

- (NSInteger)saturation
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_SATURATION, &currentValue);
    });
    
    return currentValue;
}


- (void)setGamma:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_GAMMA, (uint32_t)newValue);
    });
}

- (NSInteger)gamma
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_GAMMA, &currentValue);
    });
    
    return currentValue;
}



- (void)setGain:(NSInteger)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_set_value(_camera, DC1394_FEATURE_GAIN, (uint32_t)newValue);
    });
}

- (NSInteger)gain
{
    __block uint32_t currentValue;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_get_value(_camera, DC1394_FEATURE_GAIN, &currentValue);
    });
    
    return currentValue;
}

// This must be done differently -JKC
- (void)setWhiteBalance:(uint32_t)newWhiteBalanceU whiteBalanceV:(uint32_t)newWhiteBalanceV
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_feature_whitebalance_set_value(_camera, newWhiteBalanceU, newWhiteBalanceV);
    });
}

- (NSInteger)whiteBalanceU
{
    __block uint32_t whiteBalanceU;
    __block uint32_t whiteBalanceV;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_whitebalance_get_value(_camera, &whiteBalanceU, &whiteBalanceV);
    });
    
    return whiteBalanceU;
}

- (NSInteger)whiteBalanceV
{
    __block uint32_t whiteBalanceU;
    __block uint32_t whiteBalanceV;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_feature_whitebalance_get_value(_camera, &whiteBalanceU, &whiteBalanceV);
    });
    
    return whiteBalanceV;
}


@end
