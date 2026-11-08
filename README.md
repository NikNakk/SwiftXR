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
14. Capture the ordinary macOS mouse/trackpad exclusively for XR without moving or clicking the desktop cursor.
15. Optionally enumerate and control Monado service clients through a dynamically loaded `libmonado`, without making Monado a build-time dependency of SwiftXR.

`XRView` exposes `viewMatrix`, `projectionMatrix(nearZ:farZ:)`, and `viewProjectionMatrix(nearZ:farZ:)`.

## Host input and XR panels

SwiftXR deliberately does **not** provide a replacement for Apple's `GameController` framework or AppKit input model. A game should use its normal input architecture directly.

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

### Exclusive Mac pointer capture

For a mouse or trackpad used as an XR pointer, use `XRMacPointerCapture` rather than polling the normal desktop cursor:

```swift
let pointerCapture = XRMacPointerCapture(
    interaction: panel.interaction
)

try pointerCapture.start()
defer { pointerCapture.stop() }
```

While active, SwiftXR makes the process a foreground AppKit application, places transparent input-capture windows over the attached Mac displays, hides and disassociates the system cursor, and forwards relative mouse/trackpad deltas, buttons, and scrolling into `XRPanelInteraction`. The desktop pointer therefore remains stationary and desktop applications do not receive the captured clicks.

If SwiftXR loses foreground focus (for example via Cmd-Tab), capture is suspended immediately and the system cursor is restored. It is reacquired when the application becomes active again while capture is still requested. Escape releases capture and sets `escapeRequested`, which the sample uses as a request to leave XR.

This uses AppKit/Core Graphics for pointer ownership; `GCMouse` remains useful when an application specifically wants GameController's representation of a physical mouse, but it does not itself provide exclusive desktop cursor capture.

A future Sense-controller path can hit-test a 6DoF controller ray against the same panel and send a normalized panel coordinate through `movePointer(to:)`, with trigger press/release mapped to `pointerDown()`/`pointerUp()`. The panel API does not need to change when Sense 6DoF arrives.

## Optional Monado runtime control

`XRMonadoRuntimeControl` is a deliberately small runtime-specific control surface for host applications such as launchers. It is separate from the normal OpenXR API and should only be used when an application explicitly wants to manage Monado service clients.

SwiftXR loads `libmonado.dylib` at runtime with `dlopen`, so importing SwiftXR does **not** add a Monado link or header dependency. If `libmonado` is unavailable, normal OpenXR functionality is unaffected and creating `XRMonadoRuntimeControl` simply throws.

```swift
let monado = try XRMonadoRuntimeControl()
let clients = try monado.refreshClients()

for client in clients {
    print(client.id, client.name, client.state)
}

if let game = clients.first(where: { $0.name == "My Game" }) {
    try monado.setPrimary(clientID: game.id)
    try monado.setFocused(clientID: game.id)
}
```

The typed client state exposes Monado's primary, active, visible, focused, overlay and IO-block flags.

Library lookup checks `SWIFTXR_LIBMONADO_PATH` first, then reads the runtime manifest selected by `XR_RUNTIME_JSON`, or the standard `active_runtime.json` locations when unset. Manifest symlinks are resolved before interpreting relative `MND_libmonado_path` and `library_path` values. It also checks development-build paths, the normal dynamic-loader path, and common `/usr/local/lib` and `/opt/homebrew/lib` locations.

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

A hosted interactive SwiftUI surface in XR. The sample contains real `Button`, `Toggle`, and `Slider` controls, draws a virtual cursor in the headset, uses `XRMacPointerCapture` for exclusive mouse/trackpad interaction, and continues to accept normal `GameController` navigation input.

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
11. ✅ exclusive macOS mouse/trackpad capture for XR UI
12. Next: refine panel focus/navigation behavior, then add OpenXR actions/Sense controllers and haptics when the runtime tracking work is ready.

The OpenXR development headers and loader library (`libopenxr_loader`) must be available to the compiler/linker. On macOS a default CMake install commonly places `libopenxr_loader.dylib` in `/usr/local/lib`; the example executables include that directory in their link and runtime search paths.

## Non-goals

SwiftXR should not contain headset-specific tracking algorithms, compositor scheduling policy, or runtime-specific device handling. Those remain runtime responsibilities below OpenXR. The optional Monado control wrapper is host/runtime orchestration rather than device implementation.


## Tracked panel input (local development)

Create one `XRControllerInput(session:)` before starting a session. It creates
and attaches its OpenXR action set once; applications that own additional action
sets must coordinate their attachment rather than attach another set later.
Call `poll(predictedDisplayTime:)` inside the frame encoding callback, using the
current `XRFrame.predictedDisplayTime`. Aim poses are located in the session's
LOCAL reference space, matching the rendered views.

The snapshot exposes left/right aim poses, trigger select, primary face button,
grip, back, menu, home, recenter and thumbstick states. `isFocused` gates
interaction; `isActive` identifies an available hand even when its aim pose is
temporarily invalid. Button values are levels: clients should detect edges and
suppress held buttons when entering a mode, connecting a controller or regaining
focus.

`menu` is the application menu button and `home` the system button that shells
use to return to their home view. `XRInstance` enables `XR_MNDX_psvr2_interaction`
and `XR_KHR_generic_controller` whenever the runtime offers them
(`enabledInputExtensions`), and `XRControllerInput` suggests one binding set per
interaction profile; the runtime picks one per controller, preferring the
controller's own profile:

| Profile | Primary | Back | Recenter | Menu | Home |
| --- | --- | --- | --- | --- | --- |
| PS VR2 Sense (MNDX) | Square / Cross | Circle | Triangle | Create | PS (either hand) |
| Generic controller (KHR) | primary (both hands) | right secondary | left secondary | — | — |
| Oculus Touch | X / A | B | Y | left menu | right system |
| Simple controller | — | — | — | menu | — |

Options on the Sense controllers is left unbound because holding it recentres in
Monado. The generic profile has no menu or system button by design. Runtimes may
withhold system buttons from applications. No haptic output is configured.

For panels with separately drawn cursors, set
`panel.refreshesOnPointerMovement = false` to avoid a complete SwiftUI bitmap and
texture upload on each hover move. Observe model changes and call `invalidate()`
for hover-driven content; button, drag, key and scroll events still schedule
refreshes. `refreshIfNeeded()` returns whether it rasterised the panel, allowing
callers to measure or regression-test unnecessary redraws. Pointer exit followed
by pointer-up cancels a drag outside the host instead of clicking its last hit.


### Panel uploads and frame-thread ownership

Panel capture and semantic AppKit input remain main-actor operations. Set
`usesImmutableTextures = true` when a separate XR thread samples the panel;
after refreshing, publish the new `texture` to that thread and retain the old
texture until its GPU work is complete. The default keeps texture identity
stable for existing single-threaded renderers. Uploads use a reusable BGRA CPU
bitmap with one texture upload, avoiding a temporary Metal texture/readback.
Native semantic scrolling resolves the hit-tested scroll view (or the panel's
main vertical scroll view), preserves fractional points and constrains its clip
bounds; it does not rely on a windowless synthetic wheel event.

A caller may move its OpenXR session/frame loop to a dedicated thread provided
it serializes **all** operations on that session, stops and joins the worker
before changing ownership, and never calls AppKit from the worker. Input
snapshots and immutable textures can cross the boundary; XR frame submission
must not synchronously wait for UI work.

`XRSession.referenceSpaceChangeGeneration` and `referenceSpaceChangeTime`
expose runtime LOCAL/STAGE reset events after `pollEvents()`. Reposition UI from
a located frame at or after the effective time, rather than racing the runtime
with a duplicate button-hold gesture.


Off-screen hosting windows honor the requested `scale`, independent of the
Mac display's Retina density, and reuse their capture bitmap. `scrollInfo` is
captured with the texture: its viewport is normalized top-left XYWH and its
offset is measured in viewport heights. A renderer can retain adjacent immutable
captures and interpolate their scroll positions without moving headers/footers.
The client must reset such interpolation on layout/content changes and align the
visual position to native coordinates before a pointer click.


Capture bitmap reuse clears all pixels before `cacheDisplay`, preserving alpha
across redraws and mode changes. The captured scroll viewport excludes a native
legacy scrollbar gutter, so clients should interpolate the full reported
viewport rather than reserve an arbitrary strip for an overlay scroller. Pointer
hover is delivered without making the off-screen host window key; activation,
keys, scrolling and dragging establish the responder chain when needed.
