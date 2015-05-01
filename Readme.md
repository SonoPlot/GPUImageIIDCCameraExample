# GPUImageIIDCCamera #

Janie Clayton

Brad Larson

SonoPlot, Inc.

http://www.sonoplot.com

## Overview ##

This is an extension to the [GPUImage](https://github.com/BradLarson/GPUImage) framework that adds support for FireWire and USB 3.0 cameras that rely on the IIDC communications specification. Currently, this has only been tested for the Unibrain Fire-I, Point Grey Research Flea2, and Point Grey Research Blackfly cameras.

## Licensing ##

BSD-style, with the full license available with the framework in License.txt.

This extension relies on the [libdc1394 library](http://damien.douxchamps.net/ieee1394/libdc1394/) which is maintained by Damien Douxchamps. libdc1394 is licensed under the [GNU Lesser General Public License](www.gnu.org/copyleft/lesser.html) (LGPL).

## Usage ##

This repository is built around a sample application that connects to and displays frames from an IIDC camera. The core files are GPUImageIIDCCamera.h and GPUImageIIDCCamera.m. To use this class in your project, simply copy those two files into your application.

You will also need to add the libdc1394.22.dylib and libusb-1.0.0.dylib precompiled shared libraries to your application and to copy over the Frameworks/include directory. Your application will need to link against these libraries and to search for headers in the include/ directory.

After that, you can follow the instructions in the [GPUImage readme](https://github.com/BradLarson/GPUImage) to install and set up GPUImage within your project. Once you have that, a GPUImageIIDCCamera will behave just like any other camera source and will provide frames for GPUImage to handle in a GPU-accelerated manner.