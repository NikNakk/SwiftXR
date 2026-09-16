# OpenXR overlays in SwiftXR

SwiftXR has opt-in support for `XR_EXTX_overlay` for host/system applications that need to render over another OpenXR application.

Normal SwiftXR applications are unchanged. Overlay support is only enabled when requested:

```swift
let capabilities = try XRRuntime.capabilities()
try capabilities.requireOverlay()

let instance = try XRInstance(
    applicationName: "My Overlay",
    enableOverlay: true
)
let session = try instance.system().makeSession(
    kind: .overlay(layerPlacement: 100)
)
let swapchain = try session.makeStereoSwapchain()
```

An overlay session follows the same lifecycle and frame pacing as a normal `XRSession`. When rendering a transparent overlay over the main application, submit the projection layer with source-alpha blending:

```swift
try session.renderFrame(
    to: swapchain,
    compositionLayerOptions: [.blendTextureSourceAlpha]
) { frame, texture, commandBuffer in
    // Clear unused pixels to alpha 0 and render the overlay into each eye.
}
```

When the overlay has nothing visible to submit, call `session.nextFrame()` so the OpenXR frame loop continues while submitting no composition layer.

`XR_EXTX_overlay` is not required by OpenXR runtimes. `XRRuntimeCapabilities.supportsOverlay` reports whether it is advertised and `requireOverlay()` throws when unavailable.

The overlay API is independent of SwiftXR's optional `XRMonadoRuntimeControl`; the latter is only needed for Monado-specific client orchestration such as changing primary/focused clients.
