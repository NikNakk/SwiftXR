# SwiftXR

`SwiftXR` is an experimental Swift-facing OpenXR layer for macOS. It is deliberately a thin wrapper around the standard OpenXR API. It is runtime-agnostic: Monado is the first runtime being used for development and testing, but applications should not import Monado internals or depend on a Monado source checkout.

## Design goals

- Make a simple native Swift + Metal OpenXR application small and readable.
- Use standard OpenXR concepts and the Khronos loader rather than a runtime-specific application API.
- Hide C structure initialization, fixed-size arrays, `next` chains, handle lifetime and frame-loop plumbing where doing so does not obscure OpenXR semantics.
- Expose Metal objects as normal Swift/Metal objects at the public API boundary.
- Keep the framework below the level of a scene engine. SwiftXR should be closer to MetalKit than to Unity, Godot or RealityKit.

## Current milestone: rendered stereo projection

SwiftXR can now:

1. Enumerate runtime extensions and require `XR_KHR_metal_enable`.
2. Create/destroy an OpenXR instance and expose runtime properties.
3. Select an HMD system and expose graphics/tracking properties.
4. Obtain the runtime-selected `MTLDevice` and create the required command queue from it.
5. Create a Metal-backed OpenXR session and `LOCAL` reference space.
6. Handle the core OpenXR session lifecycle and exit conditions.
7. Run paced frames through `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews`, and `xrEndFrame`.
8. Expose predicted timing, stereo poses/FOVs, and view-tracking validity as Swift values.
9. Query recommended stereo view dimensions and runtime-supported Metal swapchain formats.
10. Create one stereo OpenXR swapchain with `arraySize=2` and bridge its `XrSwapchainImageMetalKHR` images to `MTLTextureType2DArray` textures.
11. Own the acquire/wait/Metal-submit/release sequence for each rendered frame.
12. Submit an `XrCompositionLayerProjection` whose two views use array slices 0 and 1.

The rendered-frame API hands application code an `XRFrame`, the acquired two-layer `MTLTexture`, and an `MTLCommandBuffer`. SwiftXR keeps the OpenXR swapchain/frame state machine out of the application and waits for the final Metal command buffer before destroying the swapchain.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker when building and running SwiftXR.

On macOS, a default CMake installation of the Khronos OpenXR loader commonly places `libopenxr_loader.dylib` in `/usr/local/lib`. The SwiftXR example executables therefore include `/usr/local/lib` in their runtime library search path. Applications that consume SwiftXR as a library should likewise ensure that their executable can locate the OpenXR loader installed on the system.

## Example program

`Examples/HelloSwiftXR/main.swift` is a small application using only the public SwiftXR API. It creates a real Metal-backed OpenXR session and stereo array swapchain, then renders 360 projection frames. For this first visual checkpoint, both eye slices are cleared to the same smoothly pulsing blue colour before the projection layer is submitted.

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
Stereo swapchain: <width>x<height>, images=<count>, arraySize=2
Swapchain Metal pixel format: <format>
Session state: ready
Session running: yes
Rendering 360 stereo projection frames; the headset should show a pulsing blue field
Frame 0: views=2 shouldRender=true period=<period>ms
...
Completed 360 rendered OpenXR frames
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
3. ✅ `XRSession`: create a command queue from the runtime-provided `MTLDevice`, create the Metal session, handle session-state transitions and create a `LOCAL` reference space.
4. ✅ `XRFrame`: wrap `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews` and frame submission with predicted timing and Swift view values.
5. ✅ `XRSwapchain`: create and enumerate a stereo Metal array swapchain and expose its `MTLTexture` images safely.
6. ✅ Submit a real stereo projection layer from Swift/Metal through OpenXR.
7. Next: replace the diagnostic clear with a small world-space scene and add view/projection matrix helpers.

Input/actions, controllers, haptics, hand tracking and higher-level scene helpers are deliberately post-v0.1. They should be layered on after the rendering/session API has settled.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR.
