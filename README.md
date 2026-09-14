# SwiftXR

`SwiftXR` is an experimental Swift-facing OpenXR layer for macOS. It is deliberately a thin wrapper around the standard OpenXR API. It is runtime-agnostic: Monado is the first runtime being used for development and testing, but applications should not import Monado internals or depend on a Monado source checkout.

## Design goals

- Make a simple native Swift + Metal OpenXR application small and readable.
- Use standard OpenXR concepts and the Khronos loader rather than a runtime-specific application API.
- Hide C structure initialization, fixed-size arrays, `next` chains, handle lifetime and frame-loop plumbing where doing so does not obscure OpenXR semantics.
- Expose Metal objects as normal Swift/Metal objects at the public API boundary.
- Keep the framework below the level of a scene engine. SwiftXR should be closer to MetalKit than to Unity, Godot or RealityKit.

## Current milestone: live OpenXR frame loop

SwiftXR can now:

1. Enumerate runtime extensions and require `XR_KHR_metal_enable`.
2. Create and destroy an OpenXR instance through `XRInstance`.
3. Expose the runtime name and version.
4. Select a head-mounted-display system through `XRSystem`.
5. Expose useful system graphics/tracking properties.
6. Call `xrGetMetalGraphicsRequirementsKHR` and bridge the runtime-provided Metal device to a normal Swift `MTLDevice`.
7. Create an `MTLCommandQueue` from that exact runtime-provided device and use it in `XrGraphicsBindingMetalKHR`.
8. Create and destroy a Metal-backed OpenXR session through `XRSession`.
9. Create the required core `LOCAL` reference space.
10. Poll OpenXR events and automatically perform the required `READY` → `xrBeginSession` and `STOPPING` → `xrEndSession` lifecycle transitions.
11. Surface `EXITING`, `LOSS_PENDING`, and instance-loss conditions through `shouldExit`.
12. Run paced OpenXR frames through `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews`, and `xrEndFrame`.
13. Expose predicted display timing, `shouldRender`, stereo poses/FOVs, and view tracking validity as Swift value types.

The current frame path deliberately submits zero composition layers. That isolates frame timing and head tracking from swapchain/rendering work before the first visual sample is added.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker when building and running SwiftXR.

On macOS, a default CMake installation of the Khronos OpenXR loader commonly places `libopenxr_loader.dylib` in `/usr/local/lib`. The SwiftXR example executables therefore include `/usr/local/lib` in their runtime library search path. Applications that consume SwiftXR as a library should likewise ensure that their executable can locate the OpenXR loader installed on the system.

## Example program

`Examples/HelloSwiftXR/main.swift` is a deliberately small application using only the public SwiftXR API. It creates a real Metal-backed OpenXR session, creates a `LOCAL` reference space, waits for `READY`, then runs 360 zero-layer frames while printing live stereo view poses and tracking validity before requesting a clean session exit.

Run it with:

```sh
swift run hello-swiftxr
```

A successful run should include output similar to:

```text
Hello from SwiftXR
Metal graphics support: yes
Runtime: Monado <version>
System: <HMD name>
Metal device: <Apple GPU name>
LOCAL reference space: created
Session state: ready
Session running: yes
Running 360 zero-layer frames; move the headset to exercise live view poses
Frame 0: views=2 shouldRender=true period=<period>ms
  left  position: (...)
  right position: (...)
  left orientation xyzw: (...)
  tracking: orientation valid=true tracked=true; position valid=true tracked=true
...
Completed 360 OpenXR frames
Requesting clean session exit
Session state: stopping
Session state: exiting
Session exit acknowledged by runtime
```

There is also a smaller loader/runtime diagnostic executable:

```sh
swift run swiftxr-probe
```

## Intended v0.1 API boundary

The application-facing shape should converge on something like:

```swift
import Metal
import SwiftXR

let app = try XRApplication()

try app.run { frame, commandBuffer in
    for view in frame.views {
        renderScene(
            into: view.texture,
            viewMatrix: view.viewMatrix,
            projectionMatrix: view.projectionMatrix,
            commandBuffer: commandBuffer
        )
    }
}
```

The exact naming is intentionally not frozen yet. The important boundary is that application code should receive predicted frame timing, located views and Metal render targets without manually driving the OpenXR frame and swapchain state machines.

## v0.1 implementation sequence

1. ✅ `XRInstance`: create/destroy an instance with `XR_KHR_metal_enable` and expose runtime properties.
2. ✅ `XRSystem`: select the HMD system, expose system properties and query the required Metal device.
3. ✅ `XRSession`: create a command queue from the runtime-provided `MTLDevice`, create the Metal session, handle OpenXR session-state transitions and create a `LOCAL` reference space.
4. ✅ `XRFrame`: wrap `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews` and zero-layer `xrEndFrame` with predicted timing and Swift view values.
5. `XRSwapchain`: create the stereo Metal swapchain, enumerate `XrSwapchainImageMetalKHR`, and expose the resulting `MTLTexture` objects safely.
6. Evolve `hello-swiftxr` into a minimal stereo scene and prove head-tracked presentation through an OpenXR runtime on macOS.

Input/actions, controllers, haptics, hand tracking and higher-level scene helpers are deliberately post-v0.1. They should be layered on after the rendering/session API has settled.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR.
