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

@property(readwrite, nonatomic) CGSize frameSize;
@property(readwrite, nonatomic) dc1394color_coding_t colorCode;

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
    
    // Determine if the camera is the specific Blackfly variant from Point Grey Research
    isBlackflyCamera = NO;
    
    if ([self supportsVideoMode:DC1394_VIDEO_MODE_FORMAT7_0] && ![self supportsVideoMode:DC1394_VIDEO_MODE_1280x960_YUV422])
    {
        NSLog(@"Blackfly camera detected");
        isBlackflyCamera = YES;
    }
    
    
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
    dispatch_async(cameraDispatchQueue, ^{
        if (dc1394_video_set_transmission(_camera,DC1394_OFF) != DC1394_SUCCESS)
        {
            NSLog(@"Error in setting transmission on");
        }
        dc1394_capture_stop(_camera);
    });
}

- (BOOL)supportsVideoMode:(dc1394video_mode_t)mode;
{
    NSLog(@"Supports Video Mode Called");
    unsigned int currentVideoMode;
    BOOL modeFound = NO;
    
    for (currentVideoMode = 0; currentVideoMode < _supportedVideoModes.num; currentVideoMode++)
    {
        if (_supportedVideoModes.modes[currentVideoMode] == mode)
        {
            modeFound = YES;
            NSLog(@"Video Mode was found");
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
        
        [self stopCameraCapture];
        
        dispatch_async(cameraDispatchQueue, ^{
            dc1394_camera_set_power(_camera,DC1394_OFF);
            dc1394_camera_free (_camera);
            _camera = NULL;
            dc1394_free (d);
            d = NULL;
        });
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
    // TODO: A dispatch semaphore to drop frames when one is already being processed
    
    dispatch_sync(cameraDispatchQueue, ^{
        int err = 0;
        dc1394video_frame_t * frame;
        
        err = dc1394_capture_dequeue(_camera, DC1394_CAPTURE_POLICY_POLL, &frame);
        if (err != DC1394_SUCCESS)
        {
            
        }
        
        if (frame->frames_behind > 5)
        {
        }
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
    });
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
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];

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
    });
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
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];

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
    });
}

- (void)deallocateUploadTexture;
{
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext useImageProcessingContext];

        glDeleteTextures(1, &yuvUploadTexture);
        free(frameMemory);
    });
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
#pragma mark External device control

- (void)turnOnLEDLight;
{
    if (isBlackflyCamera)
    {
        dispatch_async(cameraDispatchQueue, ^{
            uint32_t registerValue;
            dc1394_get_control_register(self.camera, 0x19D0, &registerValue);
            dc1394_set_control_register(self.camera, 0x19D0, (registerValue | 1));
        });
    }
}

- (void)turnOffLEDLight;
{
    if (isBlackflyCamera)
    {
        dispatch_async(cameraDispatchQueue, ^{
            uint32_t registerValue;
            dc1394_get_control_register(self.camera, 0x19D0, &registerValue);
            dc1394_set_control_register(self.camera, 0x19D0, (registerValue | 0));
        });
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

- (void)setOperationMode:(dc1394operation_mode_t)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_video_set_operation_mode(_camera, newValue);
    });
}

- (dc1394operation_mode_t)operationMode
{
    __block uint32_t currentMode;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_video_get_operation_mode(_camera, &currentMode);
    });
    
    return currentMode;
}

- (void)setVideoMode:(dc1394video_mode_t)newMode;
{
    if (![self supportsVideoMode:newMode]) {
        NSLog(@"video mode was not supported");
        return;
    }
    dispatch_async(cameraDispatchQueue, ^{
        NSLog(@"Set Video Mode Called");
        NSLog(@"New Mode in setVideoMode: %i", newMode);

        dc1394_video_set_mode(_camera, newMode);
            
            if (newMode < 88) {
                
                switch (self.videoMode) {
                    case DC1394_VIDEO_MODE_160x120_YUV444:
                        self.frameSize = CGSizeMake(160, 120);
                        break;
                        
                    case DC1394_VIDEO_MODE_320x240_YUV422:
                        self.frameSize = CGSizeMake(320, 240);
                        break;
                        
                    case DC1394_VIDEO_MODE_640x480_YUV411:
                    case DC1394_VIDEO_MODE_640x480_YUV422:
                    case DC1394_VIDEO_MODE_640x480_RGB8:
                    case DC1394_VIDEO_MODE_640x480_MONO8:
                    case DC1394_VIDEO_MODE_640x480_MONO16:
                        self.frameSize = CGSizeMake(640, 480);
                        break;
                        
                    case DC1394_VIDEO_MODE_800x600_YUV422:
                    case DC1394_VIDEO_MODE_800x600_RGB8:
                    case DC1394_VIDEO_MODE_800x600_MONO8:
                    case DC1394_VIDEO_MODE_800x600_MONO16:
                        self.frameSize = CGSizeMake(800, 600);
                        break;
                        
                    case DC1394_VIDEO_MODE_1024x768_YUV422:
                    case DC1394_VIDEO_MODE_1024x768_RGB8:
                    case DC1394_VIDEO_MODE_1024x768_MONO8:
                    case DC1394_VIDEO_MODE_1024x768_MONO16:
                        self.frameSize = CGSizeMake(1024, 768);
                        break;
                        
                    case DC1394_VIDEO_MODE_1280x960_YUV422:
                    case DC1394_VIDEO_MODE_1280x960_RGB8:
                    case DC1394_VIDEO_MODE_1280x960_MONO8:
                    case DC1394_VIDEO_MODE_1280x960_MONO16:
                        self.frameSize = CGSizeMake(1280, 960);
                        break;
                        
                    case DC1394_VIDEO_MODE_1600x1200_YUV422:
                    case DC1394_VIDEO_MODE_1600x1200_RGB8:
                    case DC1394_VIDEO_MODE_1600x1200_MONO8:
                    case DC1394_VIDEO_MODE_1600x1200_MONO16:
                        self.frameSize = CGSizeMake(1600, 1200);
                        break;
                        
                    default:
                        // This is where the unhandled case DC1394_VIDEO_MODE_EXIF would fall. -JKC
                        break;
                }
                
                // TODO: Ask Brad where this needs to be used and so forth because right not this goes to a dead end. -JKC
                switch (self.videoMode) {
                    case DC1394_VIDEO_MODE_160x120_YUV444:
                        self.colorCode = DC1394_COLOR_CODING_YUV444;
                        break;
                        
                    case DC1394_VIDEO_MODE_320x240_YUV422:
                    case DC1394_VIDEO_MODE_640x480_YUV422:
                    case DC1394_VIDEO_MODE_800x600_YUV422:
                    case DC1394_VIDEO_MODE_1024x768_YUV422:
                    case DC1394_VIDEO_MODE_1280x960_YUV422:
                    case DC1394_VIDEO_MODE_1600x1200_YUV422:
                        self.colorCode = DC1394_COLOR_CODING_YUV422;
                        break;
                        
                    case DC1394_VIDEO_MODE_640x480_YUV411:
                        self.colorCode = DC1394_COLOR_CODING_YUV411;
                        break;
                        
                    case DC1394_VIDEO_MODE_640x480_RGB8:
                    case DC1394_VIDEO_MODE_800x600_RGB8:
                    case DC1394_VIDEO_MODE_1024x768_RGB8:
                    case DC1394_VIDEO_MODE_1280x960_RGB8:
                    case DC1394_VIDEO_MODE_1600x1200_RGB8:
                        self.colorCode = DC1394_COLOR_CODING_RGB8;
                        break;
                        
                    case DC1394_VIDEO_MODE_640x480_MONO8:
                    case DC1394_VIDEO_MODE_800x600_MONO8:
                    case DC1394_VIDEO_MODE_1024x768_MONO8:
                    case DC1394_VIDEO_MODE_1280x960_MONO8:
                    case DC1394_VIDEO_MODE_1600x1200_MONO8:
                        self.colorCode = DC1394_COLOR_CODING_MONO8;
                        break;
                        
                    case DC1394_VIDEO_MODE_640x480_MONO16:
                    case DC1394_VIDEO_MODE_800x600_MONO16:
                    case DC1394_VIDEO_MODE_1024x768_MONO16:
                    case DC1394_VIDEO_MODE_1280x960_MONO16:
                    case DC1394_VIDEO_MODE_1600x1200_MONO16:
                        self.colorCode = DC1394_COLOR_CODING_MONO16;
                        break;
                        
                    default:
                        // This is where the unhandled case DC1394_VIDEO_MODE_EXIF would fall. -JKC
                        break;
                        
                }
                
            }
        
    });
    
    if (isBlackflyCamera)
    {
        if (newMode == DC1394_VIDEO_MODE_FORMAT7_0)
        {
            // Believe this is all necessary to guarantee solid USB 3.0 connections
            dispatch_async(cameraDispatchQueue, ^{
                dc1394_format7_set_packet_size(self.camera, DC1394_VIDEO_MODE_FORMAT7_0, 4000);
            });
        }
    }
}

- (dc1394video_mode_t)videoMode
{
    __block dc1394video_mode_t currentMode;
    
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_video_get_mode(_camera, &currentMode);
        NSLog(@"current video mode: %i", currentMode);
    });
    
    return currentMode;
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

- (void)setIsoSpeed:(dc1394speed_t)newValue
{
    dispatch_async(cameraDispatchQueue, ^{
        dc1394_video_set_iso_speed(_camera, newValue);
    });
}

- (dc1394speed_t)isoSpeed
{
    __block dc1394speed_t currentSpeed;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_video_get_iso_speed(_camera, &currentSpeed);
    });
    
    return currentSpeed;
}

- (void)setRegionOfInterest:(CGRect)newValue
{
    NSLog(@"Video Mode being sent to set the image size: %i", self.videoMode);
    if (self.videoMode > 87)
    {
        // Throw an exception because it is not Format 7
        NSAssert(false, @"Video Format Is Not Format 7");
    }
    
    dispatch_async(cameraDispatchQueue, ^{
        if (isBlackflyCamera)
        {
            dc1394_format7_set_color_coding(_camera, DC1394_VIDEO_MODE_FORMAT7_0, DC1394_COLOR_CODING_YUV422);
            dc1394_format7_set_image_size(_camera, DC1394_VIDEO_MODE_FORMAT7_0, 644, 482);
            self.frameSize = CGSizeMake(644,482);
        }
        else
        {
            uint32_t bpp;
            if (dc1394_format7_get_recommended_packet_size(_camera, DC1394_VIDEO_MODE_FORMAT7_0, &bpp)!=DC1394_SUCCESS)
            {
                NSLog(@"Camera: Can't get recommanded bpp, using DC1394_USE_MAX_AVAIL");
            }

            dc1394_format7_set_roi(_camera, DC1394_VIDEO_MODE_FORMAT7_0,
                                         DC1394_COLOR_CODING_YUV422,
                                         bpp, // use recommended packet size
                                         newValue.origin.x, newValue.origin.y, // left, top
                                         newValue.size.width, newValue.size.height);
            self.frameSize = newValue.size;
        }
        
    });
}

// how do we obtain the ROI and turn it into a CGRect?
- (CGRect)regionOfInterest
{
    __block uint32_t width;
    __block uint32_t height;
    
    dispatch_sync(cameraDispatchQueue, ^{
        dc1394_format7_get_image_size(_camera, self.videoMode, &width, &height);
    });
    
    return CGRectMake((width / 2), (height / 2), width, height);
}

- (void)setFrameSize:(CGSize)newValue;
{
    _frameSize = newValue;
    
    if (frameMemory != NULL) {
        [self deallocateUploadTexture];
        [self initializeUploadTextureForSize:_frameSize];
    } else {
        [self initializeUploadTextureForSize:_frameSize];
    }
}

@end
