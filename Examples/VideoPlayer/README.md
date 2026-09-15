# SwiftXR video player proof of concept

This example ports the first GAV + Monado/OpenXR video proof of concept onto SwiftXR.

The architecture is intentionally small:

```text
local movie
   ↓
AVPlayer / AVPlayerItemVideoOutput
   ↓
BGRA CVPixelBuffer
   ↓
CVMetalTexture on SwiftXR's runtime-selected MTLDevice
   ↓
world-locked Metal quad
   ↓
SwiftXR stereo OpenXR swapchain
   ↓
OpenXR runtime (Monado initially)
   ↓
PSVR2
```

AVPlayer remains the media clock and plays the movie audio. SwiftXR owns the OpenXR instance/session lifecycle, view location, swapchain acquisition/release and projection-layer submission.

## Current scope

Included in the first version:

- local movie files;
- AVFoundation video decode and audio playback;
- BGRA `AVPlayerItemVideoOutput` frames;
- zero-CPU-copy CoreVideo → Metal texture wrapping;
- the exact Metal device selected by the OpenXR runtime;
- world-locked flat video surface in LOCAL space;
- aspect-ratio-preserving screen sizing matching the GAV OpenXR POC;
- stereo rendering through SwiftXR's normal two-slice swapchain;
- no extra per-frame CPU wait for Metal completion.

Deferred deliberately until this path is proven on-device:

- SwiftUI transport controls;
- seeking / play-pause input;
- explicit PSVR2 audio routing;
- SBS / over-under stereo;
- 180°, 360°, fisheye and EAC projections;
- HDR / colour-space work;
- URL / yt-dlp input;
- ambisonic audio.

For the first test use a conventional landscape SDR H.264/HEVC MP4.

## Run

From the SwiftXR repository:

```sh
XR_RUNTIME_JSON=/path/to/openxr_monado-dev.json \
  swift run swiftxr-video /path/to/movie.mp4
```

If the OpenXR loader is not already discoverable through the executable rpath, use the same loader environment as the other SwiftXR examples.

Playback starts when the OpenXR session reaches READY. Audio follows the current macOS output device. Press Ctrl-C to terminate the proof of concept.

## What success proves

A stable world-locked flat movie with synchronized audio demonstrates that:

1. AVFoundation can decode into IOSurface-backed buffers usable by the runtime-selected Metal device.
2. SwiftXR can consume those textures directly in a normal stereo projection frame.
3. SwiftXR replaces the hand-written OpenXR plumbing from the GAV POC without changing the media architecture.

The next step is to add the already-proven SwiftUI panel/input path for transport controls, then port the existing GAV immersive projection shaders one mode at a time.
