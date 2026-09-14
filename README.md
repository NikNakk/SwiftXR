# SwiftXR

`SwiftXR` is an experimental Swift-facing OpenXR layer for macOS. It is deliberately a thin wrapper around the standard OpenXR API. It is runtime-agnostic: Monado is the first runtime being used for development and testing, but applications should not import Monado internals or depend on a Monado source checkout.

## Design goals

- Make a simple native Swift + Metal OpenXR application small and readable.
- Use standard OpenXR concepts and the Khronos loader rather than a runtime-specific application API.
- Hide C structure initialization, fixed-size arrays, `next` chains, handle lifetime and frame-loop plumbing where doing so does not obscure OpenXR semantics.
- Expose Metal objects as normal Swift/Metal objects at the public API boundary.
- Keep the framework below the level of a scene engine. SwiftXR should be closer to MetalKit than to Unity, Godot or RealityKit.

## Current milestone: instance and system discovery

SwiftXR can now:

1. Enumerate runtime extensions and require `XR_KHR_metal_enable`.
2. Create and destroy an OpenXR instance through `XRInstance`.
3. Expose the runtime name and version.
4. Select a head-mounted-display system through `XRSystem`.
5. Expose useful system graphics/tracking properties.
6. Call `xrGetMetalGraphicsRequirementsKHR` and bridge the runtime-provided Metal device to a normal Swift `MTLDevice`.

The Metal device returned by the runtime is important: the command queue passed to the future Metal-backed OpenXR session must be created from that device.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker when building and running SwiftXR.

On macOS, a default CMake installation of the Khronos OpenXR loader commonly places `libopenxr_loader.dylib` in `/usr/local/lib`. The SwiftXR example executables therefore include `/usr/local/lib` in their runtime library search path. Applications that consume SwiftXR as a library should likewise ensure that their executable can locate the OpenXR loader installed on the system.

## Example program

`Examples/HelloSwiftXR/main.swift` is a deliberately small application using only the public SwiftXR API. It now opens the runtime far enough to identify the runtime, HMD system and required Metal device.

Run it with:

```sh
swift run hello-swiftxr
```

A successful run should report values similar to:

```text
Hello from SwiftXR
Metal graphics support: yes
Runtime: Monado <version>
System: <HMD name>
Vendor ID: <vendor>
Max swapchain image: <width>x<height>
Max compositor layers: <count>
Orientation tracking: yes
Position tracking: yes
Metal device: <Apple GPU name>
Ready to create a Metal-backed OpenXR session.
```

It does not yet create an OpenXR session or render into the headset. The next milestone is `XRSession`, reference-space creation and session-state handling.

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
3. `XRSession`: create a command queue from the runtime-provided `MTLDevice`, create the Metal session, handle OpenXR session-state transitions and reference spaces.
4. `XRFrameLoop`: wrap `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews` and `xrEndFrame` with predicted display timing.
5. `XRSwapchain`: create the stereo Metal swapchain, enumerate `XrSwapchainImageMetalKHR`, and expose the resulting `MTLTexture` objects safely.
6. Evolve `hello-swiftxr` into a minimal stereo scene and prove head-tracked presentation through an OpenXR runtime on macOS.

Input/actions, controllers, haptics, hand tracking and higher-level scene helpers are deliberately post-v0.1. They should be layered on after the rendering/session API has settled.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR.
