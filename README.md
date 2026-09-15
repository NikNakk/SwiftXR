# SwiftXR

`SwiftXR` is an experimental Swift-facing OpenXR layer for macOS. It is deliberately a thin wrapper around the standard OpenXR API. It is runtime-agnostic: Monado is the first runtime being used for development and testing, but applications should not import Monado internals or depend on a Monado source checkout.

## Design goals

- Make a simple native Swift + Metal OpenXR application small and readable.
- Use standard OpenXR concepts and the Khronos loader rather than a runtime-specific application API.
- Hide C structure initialization, fixed-size arrays, `next` chains, handle lifetime and frame-loop plumbing where doing so does not obscure OpenXR semantics.
- Expose Metal objects as normal Swift/Metal objects at the public API boundary.
- Keep the framework below the level of a scene engine. SwiftXR should be closer to MetalKit than to Unity, Godot or RealityKit.
- Do not wrap mature host input APIs unnecessarily. Games should continue to use Apple's `GameController`, AppKit, or their engine's input system directly.

## Current milestone

SwiftXR can now:

1. Enumerate runtime extensions and require `XR_KHR_metal_enable`.
2. Create/destroy an OpenXR instance and expose runtime properties.
3. Select an HMD system and expose graphics/tracking properties.
4. Obtain the runtime-selected `MTLDevice` and create the required command queue from it.
5. Create a Metal-backed OpenXR session and `LOCAL` reference space.
6. Handle the core OpenXR session lifecycle and exit conditions.
7. Run paced frames through `xrWaitFrame`, `xrBeginFrame`, `xrLocateViews`, and `xrEndFrame`.
8. Expose predicted timing, stereo poses/FOVs, and view-tracking validity as Swift values.
9. Create and drive a stereo Metal array swapchain and submit a real projection layer.
10. Convert OpenXR poses/FOVs into Metal-compatible view/projection matrices.
11. Render world-locked 6DoF Metal content independently for each eye.
12. Host normal SwiftUI views off-screen and expose them as reusable Metal textures in XR.
13. Route device-neutral panel interaction events into a real `NSHostingView` responder chain so standard SwiftUI controls can receive pointer, scroll, navigation, select, and back input.

`XRView` exposes `viewMatrix`, `projectionMatrix(nearZ:farZ:)`, and `viewProjectionMatrix(nearZ:farZ:)`.

## Host input and XR panels

SwiftXR deliberately does **not** provide a replacement for Apple's `GameController` framework or AppKit mouse handling. A game should use its normal input architecture directly.

SwiftXR instead provides a semantic interaction endpoint on each panel:

```swift
panel.interaction.navigate(.down)
panel.interaction.select()
panel.interaction.back()

panel.interaction.movePointer(to: SIMD2(0.4, 0.7))
panel.interaction.movePointer(by: SIMD2(0.01, -0.02))
panel.interaction.scroll(SIMD2(0, -1))
panel.interaction.pointerDown()
panel.interaction.pointerUp()
```

The panel is backed by an off-screen `NSHostingView` attached to an AppKit responder chain. SwiftXR translates those semantic operations into normal AppKit mouse/key events, so standard SwiftUI controls such as `Button`, `Toggle`, `Slider`, and `ScrollView` can behave normally.

The texture is not rerasterized at headset refresh rate. It is updated after interaction, or when `refresh()` is called after an application-driven model change.

### GameController example

Use `GameController` directly and forward only UI-relevant intents:

```swift
let pad = controller.extendedGamepad!

pad.dpad.down.pressedChangedHandler = { _, _, pressed in
    if pressed { panel.interaction.navigate(.down) }
}

pad.buttonA.pressedChangedHandler = { _, _, pressed in
    if pressed { panel.interaction.select() }
}

pad.buttonB.pressedChangedHandler = { _, _, pressed in
    if pressed { panel.interaction.back() }
}
```

### Mouse example

Likewise, an app can forward AppKit or `GCMouse` input directly:

```swift
override func mouseMoved(with event: NSEvent) {
    panel.interaction.movePointer(
        by: SIMD2(Float(event.deltaX), Float(-event.deltaY)) * sensitivity
    )
}

override func mouseDown(with event: NSEvent) {
    panel.interaction.pointerDown()
}

override func mouseUp(with event: NSEvent) {
    panel.interaction.pointerUp()
}

override func scrollWheel(with event: NSEvent) {
    panel.interaction.scroll(
        SIMD2(Float(event.scrollingDeltaX), Float(event.scrollingDeltaY))
    )
}
```

A future Sense-controller path can hit-test a 6DoF controller ray against the same panel and send a normalized panel coordinate through `movePointer(to:)`, with trigger press/release mapped to `pointerDown()`/`pointerUp()`. The panel API does not need to change when Sense 6DoF arrives.

## Examples

### `hello-swiftxr`

A diagnostic world-locked cube + floor-grid sample.

```sh
swift run hello-swiftxr
```

### `minimal-swiftxr-logo`

A deliberately compact application showing how little XR-specific code is needed to render a world-locked SwiftXR mark.

```sh
swift run minimal-swiftxr-logo
```

### `swiftui-panel`

A hosted interactive SwiftUI surface in XR. The sample contains real `Button`, `Toggle`, and `Slider` controls and maps Apple's `GameController` / `GCMouse` APIs directly into `panel.interaction`. It also draws a virtual cursor in the headset because the macOS system cursor is not part of the off-screen texture.

```sh
swift run swiftui-panel
```

### `swiftxr-probe`

A small loader/runtime diagnostic.

```sh
swift run swiftxr-probe
```

## Intended application-facing boundary

The rendering side is converging on:

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

For UI, applications keep their existing input system and only send panel-specific semantic events into SwiftXR.

## v0.1 implementation sequence

1. ✅ `XRInstance`
2. ✅ `XRSystem` + runtime-selected Metal device
3. ✅ Metal `XRSession` + lifecycle + `LOCAL` space
4. ✅ paced frame loop and stereo views
5. ✅ stereo Metal array swapchain
6. ✅ projection-layer submission
7. ✅ view/projection matrices + world-locked sample
8. ✅ SwiftUI-to-Metal panel rendering
9. ✅ device-neutral panel interaction boundary
10. ✅ hosted interactive SwiftUI controls with gamepad/mouse forwarding
11. Next: refine panel focus/navigation behavior, then add OpenXR actions/Sense controllers and haptics when the runtime tracking work is ready.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker. On macOS a default CMake install commonly places `libopenxr_loader.dylib` in `/usr/local/lib`; the example executables include that directory in their rpath.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR.
