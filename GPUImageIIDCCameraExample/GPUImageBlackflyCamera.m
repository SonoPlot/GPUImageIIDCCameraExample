#import "GPUImageBlackflyCamera.h"

@implementation GPUImageBlackflyCamera

- (void)turnOnLEDLight;
{
    dispatch_async(cameraDispatchQueue, ^{
        uint32_t registerValue;
        dc1394_get_control_register(self.camera, 0x19D0, &registerValue);
        dc1394_set_control_register(self.camera, 0x19D0, (registerValue | 1));
    });
}

- (void)turnOffLEDLight;
{
    dispatch_async(cameraDispatchQueue, ^{
        uint32_t registerValue;
        dc1394_get_control_register(self.camera, 0x19D0, &registerValue);
        dc1394_set_control_register(self.camera, 0x19D0, (registerValue | 0));
    });
}


- (void)setVideoMode:(dc1394video_mode_t)mode;
{
    [super setVideoMode:mode];

    if (mode == DC1394_VIDEO_MODE_FORMAT7_0)
    {
        // Believe this is all necessary to guarantee solid USB 3.0 connections
        dispatch_async(cameraDispatchQueue, ^{
            dc1394_format7_set_packet_size(self.camera, DC1394_VIDEO_MODE_FORMAT7_0, 4000);
            dc1394_format7_set_color_coding(self.camera, DC1394_VIDEO_MODE_FORMAT7_0, DC1394_COLOR_CODING_YUV422);
            dc1394_format7_set_image_size(self.camera, DC1394_VIDEO_MODE_FORMAT7_0, 644, 482);
        });
    }
}

@end
