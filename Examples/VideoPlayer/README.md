# SwiftXR video player

This example ports the GAV + Monado/OpenXR video player onto SwiftXR while keeping the media path separate from the OpenXR runtime plumbing.

```text
Files browser / YouTube browser / explicit argument
                    ↓
          MediaInputResolver / yt-dlp cache
                    ↓
          AVPlayer / AVPlayerItemVideoOutput
                    ↓
          BGRA CVPixelBuffer → CVMetalTexture
                    ↓
       flat / VR180 / fisheye / EAC360 Metal projection
                    ↓
          SwiftXR stereo OpenXR swapchain
                    ↓
          OpenXR runtime (Monado initially)
                    ↓
                   PSVR2
```

For ordinary audio, `AVPlayer` is routed directly to the PS VR2 CoreAudio device when present. If a four-channel YouTube spatial-audio sidecar is available, it is decoded to an ACN/SN3D AmbiX CAF and rendered through `AVAudioEnvironmentNode` with SwiftXR headset orientation driving the binaural listener.

## Features

- parameterless launch into an in-headset file browser, matching the GAV Monado POC flow;
- file browser starts in `~/Movies` (falling back to home), supports folders, `..`, `/Volumes`, paging and `.mp4` / `.m4v` / `.mov` files;
- in-headset YouTube VR browser driven by an off-screen `WKWebView`, including real keyboard entry in YouTube search fields;
- YouTube result interception and a `Play in PSVR2` page button that hand the selected URL back to the native player;
- YouTube URL input through `yt-dlp`, using the same cache as the GAV OpenXR POC;
- media resolution/download off the XR/AppKit main loop so the headset remains live while YouTube is prepared;
- local movie playback through AVFoundation;
- zero-CPU-copy CoreVideo → Metal texture wrapping on SwiftXR's runtime-selected `MTLDevice`;
- flat world-space virtual screen;
- SBS VR180 half-equirectangular projection;
- SBS VR180 equidistant-fisheye projection;
- mono YouTube/FFmpeg 3×2 EAC360 projection, including FFmpeg-compatible face rotations and edge padding;
- immersive scene anchored to initial gaze, with recenter and scene tilt;
- live switching between Flat / VR180 / Fisheye / EAC360;
- explicit PS VR2 audio-device routing for ordinary stereo audio;
- optional head-tracked four-channel AmbiX audio with host-clock video/audio synchronization;
- native SwiftUI in-headset transport panel with Files, YouTube, play/pause, seeking, volume, recenter and projection controls;
- GAV-style hidden/disassociated physical mouse driving the SwiftUI panel through SwiftXR's off-screen AppKit input bridge;
- game-controller browser and playback controls;
- no extra per-frame CPU wait for Metal completion.

## Dependencies

Local flat/immersive files only require the normal SwiftXR/OpenXR dependencies.

YouTube playback requires `yt-dlp` on `PATH`. Spatial-audio discovery/conversion additionally uses `ffprobe` and `ffmpeg`.

For example with Homebrew:

```sh
brew install yt-dlp ffmpeg
```

## Run

From the SwiftXR repository, launch with no media argument to open the in-headset file browser:

```sh
XR_RUNTIME_JSON=/path/to/openxr_monado-dev.json \
  swift run swiftxr-video
```

The file browser starts in `~/Movies` when available. Select **YouTube** to switch to the in-headset YouTube VR browser.

An explicit local movie still bypasses the browser and starts directly:

```sh
XR_RUNTIME_JSON=/path/to/openxr_monado-dev.json \
  swift run swiftxr-video "/path/to/movie.mp4"
```

YouTube URLs can likewise be supplied directly:

```sh
XR_RUNTIME_JSON=/path/to/openxr_monado-dev.json \
  swift run swiftxr-video "https://www.youtube.com/watch?v=VIDEO_ID"
```

The YouTube cache is shared with the mature GAV POC at:

```text
~/Library/Caches/GAVPSVR2/YouTube
```

## Files and YouTube browsers

The Files screen shows directories before supported movie files, includes a parent (`..`) entry, provides page up/down controls and can jump to `/Volumes`. The **YouTube** button switches to the browser without recreating the OpenXR session.

The YouTube screen is a 1024×512 snapshot of a real off-screen `WKWebView`, with the visible XR pointer mapped pixel-for-pixel back into the web page. It initially opens a YouTube search for `VR180 8K`. Selecting a playable `/watch` or `/shorts` result is intercepted and sent to the native SwiftXR player rather than being played inside WebKit. Watch pages also receive a **Play in PSVR2** button.

Clicking a YouTube text field makes the hidden WebKit window the keyboard target so ordinary Mac keyboard input can be used for search. Mouse/trackpad movement remains the virtual XR cursor. Browser media resolution and `yt-dlp` download happen away from the AppKit/XR main loop while a Loading panel remains live in the headset.

Once a video is loaded, the transport panel has **Files** and **YouTube** buttons so another source can be chosen without restarting SwiftXR.

## In-headset controls

The native SwiftUI transport panel is initially visible, auto-hides after four seconds of inactivity, and reappears when the physical mouse/trackpad moves. The real macOS cursor is hidden and disassociated while SwiftXR is capturing it, so desktop apps do not receive the panel clicks.

The panel provides Files, YouTube, play/pause, ±15 second seek buttons, an absolute scrubber, volume, recenter and live Flat / VR180 / Fisheye / EAC360 selection.

`Escape` releases the mouse and requests OpenXR session exit.

## Projection selection

Automatic filename hints are deliberately conservative so an unmarked normal movie remains flat:

- `EAC360` or `360` (without `180`) → EAC360;
- `fisheye` → VR180 fisheye;
- `VR180`, `180`, or `SBS` → VR180 equirectangular;
- otherwise → flat.

Override detection explicitly with:

```sh
SWIFTXR_VIDEO_PROJECTION=flat swift run swiftxr-video /path/movie.mp4
SWIFTXR_VIDEO_PROJECTION=vr180 swift run swiftxr-video /path/vr180.mp4
SWIFTXR_VIDEO_PROJECTION=fisheye swift run swiftxr-video /path/fisheye.mp4
SWIFTXR_VIDEO_PROJECTION=eac360 swift run swiftxr-video /path/eac360.mp4
```

`GAV_MONADO_PROJECTION` is also accepted as a compatibility fallback.

## Spatial audio

When a YouTube URL exposes an audio-only format with more than two channels, the resolver downloads it as an Ambisonic sidecar and caches it. The player converts the sidecar to a four-channel 48 kHz float CAF and uses Apple's headphone spatial renderer with live SwiftXR head orientation.

For a local file, supply a known four-channel AmbiX sidecar explicitly:

```sh
SWIFTXR_AMBISONIC_AUDIO=/path/to/spatial.webm \
  swift run swiftxr-video /path/to/video.mp4
```

Disable spatial-audio discovery/use with:

```sh
SWIFTXR_AMBISONIC_AUDIO=off swift run swiftxr-video ...
```

`GAV_AMBISONIC_AUDIO` is accepted as a compatibility fallback.

If the spatial path cannot be created, playback falls back to ordinary `AVPlayer` audio.

## Controller controls

In the Files browser, D-pad up/down moves selection, left/right pages, Cross/A opens the selected entry and Circle/B returns to playback (or exits if no video has been loaded).

In the YouTube browser, the left stick moves the virtual cursor, D-pad makes coarse pointer moves, right stick scrolls, Cross/A clicks and Circle/B goes back. Menu returns to the transport controls when a video is already loaded.

During playback:

- Cross / A: play or pause;
- L1 / R1: seek −15 / +15 seconds;
- D-pad left / right: seek −15 / +15 seconds;
- D-pad up / down: volume ±5%;
- Triangle / Y: recenter immersive scene;
- Menu: show/hide the transport panel;
- Circle / B: hide the transport panel;
- right stick: yaw/pitch the immersive scene.

## Current validation status

The local flat decode → Metal → SwiftXR → PSVR2 path and the underlying SwiftUI mouse-control mechanism have been validated on-device. The integrated Files/YouTube browser, immersive projection, explicit audio routing, controller and AmbiX paths compile together and are ports of the corresponding proven GAV/SwiftUI POC algorithms, but the newly integrated browser flow still requires on-device validation.
