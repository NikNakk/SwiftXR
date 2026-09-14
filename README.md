# SwiftXR

`SwiftXR` is an experimental Swift-facing OpenXR layer for macOS. It is deliberately a thin wrapper around the standard OpenXR API. It is runtime-agnostic: Monado is the first runtime being used for development and testing, but applications should not import Monado internals or depend on a Monado source checkout.

## Design goals

- Make a simple native Swift + Metal OpenXR application small and readable.
- Use standard OpenXR concepts and the Khronos loader rather than a runtime-specific application API.
- Hide C structure initialization, fixed-size arrays, `next` chains, handle lifetime and frame-loop plumbing where doing so does not obscure OpenXR semantics.
- Expose Metal objects as normal Swift/Metal objects at the public API boundary.
- Keep the framework below the level of a scene engine. SwiftXR should be closer to MetalKit than to Unity, Godot or RealityKit.

## Current milestone: world-locked stereo Metal rendering

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
13. Convert OpenXR poses and asymmetric FOVs into Metal-compatible view/projection matrices.
14. Render a true world-locked 3D scene independently for each eye.

The rendered-frame API hands application code an `XRFrame`, the acquired two-layer `MTLTexture`, and an `MTLCommandBuffer`. SwiftXR keeps the OpenXR swapchain/frame state machine out of the application and waits for the final Metal command buffer before destroying the swapchain.

`XRView` now exposes `viewMatrix`, `projectionMatrix(nearZ:farZ:)`, and `viewProjectionMatrix(nearZ:farZ:)`. The projection helper converts OpenXR's right-handed, -Z-forward asymmetric FOV into Metal's 0...1 normalized depth convention.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker when building and running SwiftXR.

On macOS, a default CMake installation of the Khronos OpenXR loader commonly places `libopenxr_loader.dylib` in `/usr/local/lib`. The SwiftXR example executables therefore include `/usr/local/lib` in their runtime library search path. Applications that consume SwiftXR as a library should likewise ensure that their executable can locate the OpenXR loader installed on the system.

## Example program

`Examples/HelloSwiftXR` is a small native Swift + Metal application built entirely on the public SwiftXR API. It creates a Metal-backed OpenXR session and stereo array swapchain, then renders a static coloured cube over a floor grid using the live per-eye OpenXR view poses and FOVs.

The scene is deliberately anchored in `LOCAL` space. The grid is placed approximately 1.5 m below the local origin and the cube roughly 2 m in front of it, so rotating, translating, leaning, or looking around the object should visibly demonstrate 6DoF world locking.

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
World renderer: cube + floor grid ready
Session state: ready
Session running: yes
Rendering 900 world-locked stereo frames; move and lean around the cube
Frame 0: views=2 shouldRender=true period=<period>ms
...
Completed 900 world-rendered OpenXR frames
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

The application-facing shape is converging on:

```swift
let swapchain = try session.makeStereoSwapchain()

try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
    for eye in frame.views.indices {
        renderScene(
            into: texture,
            arraySlice: eye,
            viewMatrix: frame.views[eye].viewMatrix,
            projectionMatrix: frame.views[eye].projectionMatrix(),
            commandBuffer: commandBuffer
        )
    }
}
```

Application code receives predicted frame timing, located views, Metal render targets and matrices without manually driving the OpenXR frame or swapchain state machines.

## v0.1 implementation sequence

1. ✅ `XRInstance`: create/destroy an instance with `XR_KHR_metal_enable` and expose runtime properties.
2. ✅ `XRSystem`: select the HMD system, expose system properties and query the required Metal device.
3. ✅ `XRSession`: create a command queue from the runtime-provided `MTLDevice`, create the Metal session, handle session-state transitions and create a `LOCAL` reference space.
4. ✅ `XRFrame`: wrap `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews` and frame submission with predicted timing and Swift view values.
5. ✅ `XRSwapchain`: create and enumerate a stereo Metal array swapchain and expose its `MTLTexture` images safely.
6. ✅ Submit a real stereo projection layer from Swift/Metal through OpenXR.
7. ✅ Add Metal view/projection matrix helpers and a world-locked 6DoF sample scene.
8. Next: refine the application-facing frame/render API, then add actions/controllers and haptics.

Input/actions, controllers, haptics, hand tracking and higher-level scene helpers are deliberately post-v0.1. They should be layered on after the rendering/session API has settled.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR.
