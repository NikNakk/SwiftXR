# SwiftXR

`SwiftXR` is an experimental Swift-facing OpenXR layer for macOS. It is deliberately a thin wrapper around the standard OpenXR API. It is runtime-agnostic: Monado is the first runtime being used for development and testing, but applications should not import Monado internals or depend on a Monado source checkout.

## Design goals

- Make a simple native Swift + Metal OpenXR application small and readable.
- Use standard OpenXR concepts and the Khronos loader rather than a runtime-specific application API.
- Hide C structure initialization, fixed-size arrays, `next` chains, handle lifetime and frame-loop plumbing where doing so does not obscure OpenXR semantics.
- Expose Metal objects as normal Swift/Metal objects at the public API boundary.
- Keep the framework below the level of a scene engine. SwiftXR should be closer to MetalKit than to Unity, Godot or RealityKit.

## Current milestone: runtime discovery

The package currently proves the lowest layer:

1. Swift can import the standard Khronos OpenXR headers.
2. Swift can call the normal OpenXR loader ABI.
3. Runtime extensions can be enumerated through a Swift-friendly wrapper.
4. `XR_KHR_metal_enable` can be required without exposing C string-array details to application code.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker when building and running SwiftXR.

## Example program

`Examples/HelloSwiftXR/main.swift` is a deliberately small application using only the public SwiftXR API. It discovers the active OpenXR runtime, lists its extensions and verifies that `XR_KHR_metal_enable` is available.

Run it with:

```sh
swift run hello-swiftxr
```

At the current milestone it does not create an OpenXR session or render into the headset. The example will evolve into the first head-tracked Metal scene as the session, frame-loop and swapchain APIs are added.

There is also a smaller diagnostic executable:

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

1. `XRInstance`: create/destroy an instance with `XR_KHR_metal_enable` and expose runtime/system properties.
2. `XRSystem`: select the HMD system and query Metal graphics requirements.
3. `XRSession`: bind an `MTLDevice`/`MTLCommandQueue`, handle OpenXR session-state transitions and reference spaces.
4. `XRFrameLoop`: wrap `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews` and `xrEndFrame` with predicted display timing.
5. `XRSwapchain`: create the stereo Metal swapchain, enumerate `XrSwapchainImageMetalKHR`, and expose the resulting `MTLTexture` objects safely.
6. Evolve `hello-swiftxr` into a minimal stereo scene and prove head-tracked presentation through an OpenXR runtime on macOS.

Input/actions, controllers, haptics, hand tracking and higher-level scene helpers are deliberately post-v0.1. They should be layered on after the rendering/session API has settled.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR.
