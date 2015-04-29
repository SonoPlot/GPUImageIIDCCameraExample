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
     vec4 processedYUVBlock = texture2DRect(inputTexture, textureCoordinate.xy).abgr;
     gl_FragColor =  ((processedYUVBlock - vec4(0.0, 0.5, 0.0, 0.5)) * vec4(0.9375 ,0.9219, 0.9375, 0.9219)) + vec4(0.0625, 0.5, 0.0625, 0.5);
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
    
    GLuint yuvUploadTexture, correctedYUVTexture, reuploadedYUVTexture;
    GLuint yuvCorrectionFramebuffer;
    
    CMTime currentFrameTime;
    NSTimeInterval actualTimeOfLastUpdate;
    
    GPUImageRotationMode outputRotation, internalRotation;
    
    unsigned char *frameMemory, *correctedFrameMemory;
}

// Frame processing and upload
- (void)processVideoFrame;
- (CGFloat)averageFrameDurationDuringCapture;
- (void)updateCurrentFrameTime;
- (void)initializeUploadTextureForSize:(CGSize)textureSize;

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
    

//    self.outputTextureOptions = yuvTextureOptions;
    
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

    // Temporary setup code for testing frame capture
    _frameSize = CGSizeMake(644, 482);
    dc1394_video_set_operation_mode(_camera, DC1394_OPERATION_MODE_1394B);
    dc1394_video_set_iso_speed(_camera, DC1394_ISO_SPEED_800);
    dc1394_format7_set_packet_size(_camera, DC1394_VIDEO_MODE_FORMAT7_0, 4000);
    dc1394_video_set_mode(_camera,DC1394_VIDEO_MODE_FORMAT7_0);
//    dc1394_video_set_framerate(camera,fps)
    dc1394_format7_set_color_coding(_camera, DC1394_VIDEO_MODE_FORMAT7_0, DC1394_COLOR_CODING_YUV422);
    dc1394_format7_set_image_size(_camera, DC1394_VIDEO_MODE_FORMAT7_0, 644, 482);
				
    // This is needed for turning on the LED for the USB 3.0 Blackfly
    uint32_t registerValue;
    dc1394_get_control_register(_camera, 0x19D0, &registerValue);
    dc1394_set_control_register(_camera, 0x19D0, (registerValue | 1));

    return YES;
}

- (void)startCameraCapture;
{
    // TODO: Figure out better way of allocating upload texture memory due to size changes
    [self initializeUploadTextureForSize:_frameSize];
    
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

- (BOOL)setVideoMode:(dc1394video_mode_t)mode;
{
    BOOL modeSet = NO;
    
    if (![self videoModeIsSupported:mode]) {
        return modeSet;
    }
    else
    {
        // Set the video mode
        dc1394_video_set_mode(_camera, mode);
        
        modeSet = YES;
        return modeSet;
    }
}

// Method to set frame size. If the mode isn't Format 7, then use the hardcoded frame size. If it is, then set it.
// Do I need to send the frame size in as a parameter if it isn't needed for non-Format 7?? Hmmm...

- (BOOL)videoModeIsSupported:(dc1394video_mode_t)mode;
{
    unsigned int currentVideoMode;
    BOOL modeFound = NO;
    
    for (currentVideoMode = 0; currentVideoMode < _supportedVideoModes.num; currentVideoMode++)
    {
        NSLog(@"Current Video Mode: %u", _supportedVideoModes.modes[currentVideoMode]);
        // The enum containing the modes starts at an index of 64, so to output the appropriate string you need to subtract 64 from the current index. -JKC
        NSLog(@"Current Video Mode: %@", [self stringForMode:_supportedVideoModes.modes[currentVideoMode]]);
        if (_supportedVideoModes.modes[currentVideoMode] == mode)
        {
            modeFound = YES;
            break;
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

static void cameraFrameReadyCallback(dc1394camera_t *camera, void *cameraObject)
{
    [(__bridge GPUImageIIDCCamera *)cameraObject captureFrameFromCamera];
}

#pragma mark -
#pragma mark Frame processing and upload

#define INITIALFRAMESTOIGNOREFORBENCHMARK 5

- (void)captureFrameFromCamera;
{
    int err = 0;
    dc1394video_frame_t * frame;
    
    err = dc1394_capture_dequeue(_camera, DC1394_CAPTURE_POLICY_POLL, &frame);
    if (err != DC1394_SUCCESS)
    {
        
    }
//    if ((_cameraType == FLEA2G) || (_cameraType == BLACKFLY))
//    {
//        //				yuv422_2vuy422_old(frame->image, videoTexturePointer, (NSUInteger)frameSize.width, (NSUInteger)frameSize.height, &currentLuminance);
//        yuv422_2vuy422(frame->image, _videoTexturePointer, (NSUInteger)_frameSize.width, (NSUInteger)_frameSize.height, &currentLuminance);
//    }
//    else
//    {
//        uyvy411_2vuy422(frame->image, _videoTexturePointer, (NSUInteger)_frameSize.width, (NSUInteger)_frameSize.height, &currentLuminance);
//    }
    
    yuv422_2vuy422(frame->image, frameMemory, (unsigned int)_frameSize.width, (unsigned int)_frameSize.height);
    dc1394_capture_enqueue(_camera, frame);
    
    [self processVideoFrame];
}

- (void)processVideoFrame;
{
    // Assume a YUV422 frame as input
    
//    if (capturePaused)
//    {
//        return;
//    }
    
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    
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
    
    // Upload to YUV texture via direct memory access
    glBindFramebuffer(GL_FRAMEBUFFER, yuvCorrectionFramebuffer);
    GLfloat yuvImageHeight = (_frameSize.width * _frameSize.height * 2) / (_frameSize.width * 4);
    glViewport(0, 0, (GLfloat)_frameSize.width, yuvImageHeight);
    
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    const GLfloat yuvConversionCoordinates[] = {
        0.0, 0.0,
        _frameSize.width, 0.0,
        0.0, yuvImageHeight,
        _frameSize.width, yuvImageHeight
    };

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, yuvUploadTexture);
    glTexSubImage2D (GL_TEXTURE_RECTANGLE_EXT, 0, 0, 0, _frameSize.width, yuvImageHeight, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, frameMemory);
    glUniform1i(yuvConversionInputTextureUniform, 4);
    
    glVertexAttribPointer(yuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
    glVertexAttribPointer(yuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, yuvConversionCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    
    // After byte reordering and colorspace correction, pull down bytes of the target texture
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, correctedYUVTexture);
    glGetTexImage(GL_TEXTURE_RECTANGLE_EXT, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, correctedFrameMemory);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, 0);
    
    // Reupload those bytes into a YUV422 texture for subsequent processing
    glBindTexture(GL_TEXTURE_2D, reuploadedYUVTexture);
    glTexSubImage2D (GL_TEXTURE_2D, 0, 0, 0, _frameSize.width, _frameSize.height, GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, correctedFrameMemory);
    glBindTexture(GL_TEXTURE_2D, 0);
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

- (void)initializeUploadTextureForSize:(CGSize)textureSize;
{
    // TODO: Deal with colorspace sizes other than YUV422
    frameMemory = (unsigned char *)malloc(textureSize.width * textureSize.height * 2);
    correctedFrameMemory = (unsigned char *)malloc(textureSize.width * textureSize.height * 2);

    GLfloat yuvImageHeight = (textureSize.width * textureSize.height * 2) / (_frameSize.width * 4);

    // Create the initial upload texture direct from the camera
    glActiveTexture(GL_TEXTURE3);
    glGenTextures(1, &yuvUploadTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, yuvUploadTexture);
    glTextureRangeAPPLE(GL_TEXTURE_RECTANGLE_EXT, textureSize.width * textureSize.height * 2, frameMemory);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_SHARED_APPLE);
    
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, textureSize.width, yuvImageHeight, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, frameMemory);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, 0);

    // Create the output texture for colorspace swizzling and range correction
    glActiveTexture(GL_TEXTURE4);
    glGenTextures(1, &correctedYUVTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, correctedYUVTexture);
    glTextureRangeAPPLE(GL_TEXTURE_RECTANGLE_EXT, textureSize.width * textureSize.height * 2, correctedFrameMemory);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_SHARED_APPLE);
    
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA, textureSize.width, yuvImageHeight, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, correctedFrameMemory);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, 0);

    glGenFramebuffers(1, &yuvCorrectionFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, yuvCorrectionFramebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_EXT, correctedYUVTexture, 0);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
    
    // Create the memory-mapped reupload texture for taking the corrected BGRA texture and putting its bytes into a YUV texture
    glActiveTexture(GL_TEXTURE2);
    glGenTextures(1, &reuploadedYUVTexture);
    glBindTexture(GL_TEXTURE_2D, reuploadedYUVTexture);
    glTextureRangeAPPLE(GL_TEXTURE_2D, textureSize.width * textureSize.height * 2, correctedFrameMemory);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_SHARED_APPLE);
    
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
    
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, textureSize.width, textureSize.height, 0, GL_YCBCR_422_APPLE, GL_UNSIGNED_SHORT_8_8_REV_APPLE, correctedFrameMemory);
    glBindTexture(GL_TEXTURE_2D, 0);

    outputFramebuffer = [[GPUImageFramebuffer alloc] initWithSize:textureSize overriddenTexture:reuploadedYUVTexture];
}

- (void)deallocateUploadTexture;
{
    glDeleteTextures(1, &yuvUploadTexture);
    free(frameMemory);
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




/*
#pragma mark -
#pragma mark Frame grabbing
- (BOOL)grabNewVideoFrame:(NSError **)error;
{
    int err = 0;
    dc1394video_frame_t * frame;
    
    err = dc1394_capture_dequeue(_camera, DC1394_CAPTURE_POLICY_POLL, &frame);
    
    if (err != DC1394_SUCCESS)
    {
        // Serious error with the camera that needs to be presented
        // Need to figure out how to detangle this from a notification. -JKC
        // Want to know how to handle this!! I assume it's rather important. -JKC
//        [[NSNotificationCenter defaultCenter] postNotificationName:kSPCameraDisconnectedNotification object:nil];
//        return NO;
    }
    
    if (frame != NULL)
    {
        while (frame->frames_behind > 2)
        {
            dc1394_capture_enqueue(_camera, frame);
            dc1394_capture_dequeue(_camera, DC1394_CAPTURE_POLICY_POLL, &frame);
            if (frame == NULL)
            {
                break;
            }
            else
            {
            }
        }
        
        if (frame == NULL)
        {
            return NO;
        }
        
        // We were doing conditional logic for the YUV remapping. -JKC
        dc1394_capture_enqueue(_camera, frame);
        
        sequentialMissedCameraFrames = 0;
        frameGrabTimedOutOnce = NO;
        
        // How much of this are we still responsible for?? -JKC
        // This seems slightly less pertinent than just grabbing frames?? -JKC
//        if (_automaticLightingCorrectionEnabled)
//        {
//            [self adjustLightSensitivity];
//        }
//        
//        if (autoSettingsToChange != 0)
//        {
//            [self updateCameraAutoSettings];
//        }
//        if (settingsToChange != 0)
//        {
//            [self updateCameraSettings];
//        
//            previousGain = _gain * FILTERFACTORFORSMOOTHINGCAMERAVALUES + (1.0 - FILTERFACTORFORSMOOTHINGCAMERAVALUES) * previousGain;
//            previousExposure =  _exposure * FILTERFACTORFORSMOOTHINGCAMERAVALUES + (1.0 - FILTERFACTORFORSMOOTHINGCAMERAVALUES) * previousExposure;
//            //			previousGain = gain;
//        }
//        
//        [self encodeVideoFrameToDiskIfNeeded];
    
        return YES;
    }
    else
    {
        sequentialMissedCameraFrames++;
        
        if (sequentialMissedCameraFrames > LOOPSWITHOUTFRAMEBEFOREERROR)
        {
            if (frameGrabTimedOutOnce)
            {
                //				err = DC1394_FAILURE;
//                [[NSNotificationCenter defaultCenter] postNotificationName:kSPCameraDisconnectedNotification object:nil];
            }
            else
            {
                sequentialMissedCameraFrames = 0;
                frameGrabTimedOutOnce = YES;
                dc1394_video_set_transmission(_camera,DC1394_OFF);
                dc1394_video_set_transmission(_camera,DC1394_ON);
            }
        }		
    }
    
    return NO;
}



// I don't know about this?? There are two declarations of this in the orginal code and it's called by the video view??
// It's the only place in the code that grabNewVideoFrame is called. -JKC
- (BOOL)isNewCameraFrameAvailable;
{
    if (!_isConnectedToCamera)
    {
        return NO;
    }
    
    NSError *error = nil;
    BOOL success = [self grabNewVideoFrame:&error];
    	if (!success)
    	{
    		NSLog(@"No frame available");
    	}
    
    return success;
}
*/

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
#pragma mark Debugging methods
- (NSString*)stringForMode:(uint32_t)mode;
{
    
    switch (mode) {
        case 64:
            return @"DC1394_VIDEO_MODE_160x120_YUV444";
            
        case 65:
            return @"DC1394_VIDEO_MODE_320x240_YUV422";
            
        case 66:
            return @"DC1394_VIDEO_MODE_640x480_YUV411";
            
        case 67:
            return @"DC1394_VIDEO_MODE_640x480_YUV422";
            
        case 68:
            return @"DC1394_VIDEO_MODE_640x480_RGB8";
            
        case 69:
            return @"DC1394_VIDEO_MODE_640x480_MONO8";
            
        case 70:
            return @"DC1394_VIDEO_MODE_640x480_MONO16";
            
        case 71:
            return @"DC1394_VIDEO_MODE_800x600_YUV422";
            
        case 72:
            return @"DC1394_VIDEO_MODE_800x600_RGB8";
            
        case 73:
            return @"DC1394_VIDEO_MODE_800x600_MONO8";
            
        case 74:
            return @"DC1394_VIDEO_MODE_1024x768_YUV422";
            
        case 75:
            return @"DC1394_VIDEO_MODE_1024x768_RGB8";
            
        case 76:
            return @"DC1394_VIDEO_MODE_1024x768_MONO8";
            
        case 77:
            return @"DC1394_VIDEO_MODE_800x600_MONO16";
            
        case 78:
            return @"DC1394_VIDEO_MODE_1024x768_MONO16";
            
        case 79:
            return @"DC1394_VIDEO_MODE_1280x960_YUV422";
            
        case 80:
            return @"DC1394_VIDEO_MODE_1280x960_RGB8";
            
        case 81:
            return @"DC1394_VIDEO_MODE_1280x960_MONO8";
            
        case 82:
            return @"DC1394_VIDEO_MODE_1600x1200_YUV422";
            
        case 83:
            return @"DC1394_VIDEO_MODE_1600x1200_RGB8";
            
        case 84:
            return @"DC1394_VIDEO_MODE_1600x1200_MONO8";
            
        case 85:
            return @"DC1394_VIDEO_MODE_1280x960_MONO16";
            
        case 86:
            return @"DC1394_VIDEO_MODE_1600x1200_MONO16";
            
        case 87:
            return @"DC1394_VIDEO_MODE_EXIF";
            
        case 88:
            return @"DC1394_VIDEO_MODE_FORMAT7_0";
            
        case 89:
            return @"DC1394_VIDEO_MODE_FORMAT7_1";
            
        case 90:
            return @"DC1394_VIDEO_MODE_FORMAT7_2";
            
        case 91:
            return @"DC1394_VIDEO_MODE_FORMAT7_3";
            
        case 92:
            return @"DC1394_VIDEO_MODE_FORMAT7_4";
            
        case 93:
            return @"DC1394_VIDEO_MODE_FORMAT7_5";
            
        case 94:
            return @"DC1394_VIDEO_MODE_FORMAT7_6";
            
        case 95:
            return @"DC1394_VIDEO_MODE_FORMAT7_7";
            
        default:
            return @"Mode Not Found";
    }
    
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


- (void)setFps:(dc1394framerate_t)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_video_set_framerate(_camera, newValue);
    });
}

- (dc1394framerate_t)fps
{
    __block dc1394framerate_t currentRate;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_video_get_framerate(_camera, &currentRate);
    });
    
    return currentRate;
}

- (void)setFilmSpeed:(dc1394speed_t)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_video_set_iso_speed(_camera, newValue);
    });
}

- (dc1394speed_t)filmSpeed
{
    __block dc1394speed_t currentSpeed;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_video_get_iso_speed(_camera, &currentSpeed);
    });
    
    return currentSpeed;
}

// Do the camera setup for things like frame rate and size
// Deal with large enum of video formats
// Deal with the possibility of Format 7
- (void)setFrameSize:(CGSize)newSize
{
    // Looking at the headers, the frame size is part of a struct associated with the frame. In the old code, the frame is instantiated
    // when we try to capture a frame. Should I just not override the frame size and deal with this stuff in the capture frame code? -JKC
    if (_res >= 88) {
        // If mode is Format 7, set the frame size directly
        self.frameSize = newSize;
    } else {
        // If not, use the built in frame size; Is part of the format description.
        // Do a giant switch statement here??
        switch (self.res) {
            case DC1394_VIDEO_MODE_160x120_YUV444:
                self.frameSize = CGSizeMake(160, 120);
                break;
                
            case DC1394_VIDEO_MODE_320x240_YUV422:
                self.frameSize = CGSizeMake(320, 240);
                break;
                
            case DC1394_VIDEO_MODE_640x480_YUV411:
                self.frameSize = CGSizeMake(640, 480);
                break;
                
            case DC1394_VIDEO_MODE_640x480_YUV422:
                self.frameSize = CGSizeMake(640, 480);
                break;
                
            case DC1394_VIDEO_MODE_640x480_RGB8:
                self.frameSize = CGSizeMake(640, 480);
                break;
                
            case DC1394_VIDEO_MODE_640x480_MONO8:
                self.frameSize = CGSizeMake(640, 480);
                break;
                
            case DC1394_VIDEO_MODE_640x480_MONO16:
                self.frameSize = CGSizeMake(640, 480);
                break;
                
            case DC1394_VIDEO_MODE_800x600_YUV422:
                self.frameSize = CGSizeMake(800, 600);
                break;
                
            case DC1394_VIDEO_MODE_800x600_RGB8:
                self.frameSize = CGSizeMake(800, 600);
                break;
                
            case DC1394_VIDEO_MODE_800x600_MONO8:
                self.frameSize = CGSizeMake(800, 600);
                break;
                
            case DC1394_VIDEO_MODE_1024x768_YUV422:
                self.frameSize = CGSizeMake(1024, 768);
                break;
                
            case DC1394_VIDEO_MODE_1024x768_RGB8:
                self.frameSize = CGSizeMake(1024, 768);
                break;
                
            case DC1394_VIDEO_MODE_1024x768_MONO8:
                self.frameSize = CGSizeMake(1024, 768);
                break;
                
            case DC1394_VIDEO_MODE_800x600_MONO16:
                self.frameSize = CGSizeMake(800, 600);
                break;
                
            case DC1394_VIDEO_MODE_1024x768_MONO16:
                self.frameSize = CGSizeMake(1024, 768);
                break;
                
            case DC1394_VIDEO_MODE_1280x960_YUV422:
                self.frameSize = CGSizeMake(1280, 960);
                break;
                
            case DC1394_VIDEO_MODE_1280x960_RGB8:
                self.frameSize = CGSizeMake(1280, 960);
                break;
                
            case DC1394_VIDEO_MODE_1280x960_MONO8:
                self.frameSize = CGSizeMake(1280, 960);
                break;
                
            case DC1394_VIDEO_MODE_1600x1200_YUV422:
                self.frameSize = CGSizeMake(1600, 1200);
                break;
                
            case DC1394_VIDEO_MODE_1600x1200_RGB8:
                self.frameSize = CGSizeMake(1600, 1200);
                break;
                
            case DC1394_VIDEO_MODE_1600x1200_MONO8:
                self.frameSize = CGSizeMake(1600, 1200);
                break;
                
            case DC1394_VIDEO_MODE_1280x960_MONO16:
                self.frameSize = CGSizeMake(1280, 960);
                break;
                
            case DC1394_VIDEO_MODE_1600x1200_MONO16:
                self.frameSize = CGSizeMake(1600, 1200);
                break;
                
            default:
                // This is where the unhandled case DC1394_VIDEO_MODE_EXIF would fall. -JKC
                break;
        }
    }
}

@end
