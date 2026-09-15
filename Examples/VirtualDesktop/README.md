# SwiftXR Virtual Desktop

This example is experimental work on branch `macos-virtual-desktop`.

## Current scope

### Stage 1 — implemented in code

`swiftxr-desktop` mirrors the primary macOS display into a world-locked OpenXR surface:

1. SwiftXR creates its normal Metal/OpenXR session and stereo swapchain.
2. ScreenCaptureKit captures the primary display at up to 60 Hz in BGRA.
3. `CVMetalTextureCache` exposes each `CVPixelBuffer` as an `MTLTexture` on the exact `MTLDevice` selected by the OpenXR runtime.
4. No CPU desktop-frame copy is performed.
5. The latest captured texture is sampled onto a 2.2 m wide, aspect-correct quad centred at `(0, 0, -2 m)` in LOCAL space.
6. The same quad is projected separately for the left and right OpenXR views.

The captured macOS cursor is currently included by ScreenCaptureKit (`showsCursor = true`).

Run with:

```bash
swift run swiftxr-desktop
```

ScreenCaptureKit requires macOS Screen Recording permission. The first capture attempt may trigger the system permission flow; macOS can require the launching app/terminal to be restarted after permission is granted.

## Stage 2 — geometry and input scaffolding implemented

`DesktopSurfaceGeometry` already provides:

- top-left-origin UV → captured desktop pixel mapping;
- UV → LOCAL-space world position;
- LOCAL-space ray → desktop hit testing (`DesktopSurfaceHit`).

This is intended for a future Sense-controller laser pointer once a stable controller pose is available.

`DesktopPointerController` provides the next bridge:

- desktop UV → Quartz global display coordinates using `CGDisplayBounds(displayID)`;
- moving the real macOS cursor with `CGWarpMouseCursorPosition`;
- opt-in primary-click and scroll event posting.

The click/scroll helpers are deliberately not wired into the demo yet. System-wide posted input may require macOS Accessibility permission and should be enabled explicitly when controller input is ready.

## Not yet implemented

- Sense-controller ray input and button actions.
- Keyboard input from XR.
- Multiple displays as separate XR surfaces.
- Movable/resizable desktop panels.
- A VR-only virtual display/extra macOS monitor.
- HDR capture path.
- Latency/cadence instrumentation between ScreenCaptureKit timestamps and OpenXR predicted display time.

## Validation still needed

The branch has not yet been exercised with the headset. In particular, validate:

- Swift 6/macOS compilation of the ScreenCaptureKit/Core Video bridge;
- Screen Recording permission behaviour when launched through SwiftPM;
- captured texture orientation and colour handling;
- display-capture latency and frame pacing;
- lifetime/synchronisation of IOSurface-backed Metal textures while the capture producer replaces the latest frame;
- practical desktop quad size/distance in PSVR2.

The design intentionally keeps all desktop-capture code in the example target for now. Once it is validated, the reusable capture/surface pieces can be promoted into SwiftXR proper without making ScreenCaptureKit a requirement for ordinary SwiftXR applications.
