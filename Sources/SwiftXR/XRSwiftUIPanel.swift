import CoreGraphics
import Metal
import SwiftUI

/// Scroll geometry captured at the same time as the panel texture. The viewport
/// is normalized top-left XYWH; offset is measured in viewport heights.
public struct XRPanelScrollInfo: Sendable, Equatable {
    public let viewport: SIMD4<Float>
    public let offset: Float
}

public enum XRSwiftUIPanelError: Error, CustomStringConvertible {
    case imageRenderingFailed
    case bitmapContextCreationFailed
    case textureCreationFailed

    public var description: String {
        switch self {
        case .imageRenderingFailed:
            return "The hosted SwiftUI surface did not produce a CGImage"
        case .bitmapContextCreationFailed:
            return "Could not create the bitmap backing for the hosted SwiftUI panel"
        case .textureCreationFailed:
            return "Could not create the Metal texture for the SwiftUI panel"
        }
    }
}

/// A hosted SwiftUI surface rendered into a shader-readable Metal texture.
///
/// On macOS the panel may be driven by a virtual pointer. Physical mouse input
/// is captured separately, converted into normalized panel coordinates, then
/// posted as ordinary AppKit mouse events addressed to this panel's off-screen
/// NSHostingView window. The visible cursor remains the XR-rendered cursor.
@MainActor
public final class XRSwiftUIPanel<Content: View> {
    private let device: any MTLDevice
    private var bitmapContext: CGContext?
    private let host: XRSwiftUIHost<Content>

    // Queued AppKit events are dispatched after the XR frame callback returns.
    // Keep refreshing for a small number of frames after input so at least one
    // rasterization occurs after SwiftUI has applied the event's state change.
    // Continuous dragging naturally keeps this counter topped up.
    private var inputRefreshFramesRemaining = 0

    /// Disable for surfaces whose cursor is drawn separately and which have no
    /// hover-dependent content. Button/drag/scroll input still refreshes the UI.
    /// Avoids a complete SwiftUI bitmap + Metal upload for every pointer move.
    public var refreshesOnPointerMovement = true
    /// Publish a new texture on refresh when a different thread may still be
    /// sampling the previous one. Consumers must fetch texture after refresh.
    public var usesImmutableTextures = false
    private var pressedPointerButtons: Set<XRPanelPointerButton> = []

    public let pointSize: CGSize
    public let scale: CGFloat

    /// Semantic panel-input endpoint for mouse capture, gamepads, ray pointers,
    /// future Sense-controller input, and other non-native pointer sources.
    public let interaction: XRPanelInteraction

    public private(set) var texture: any MTLTexture
    public private(set) var scrollInfo: XRPanelScrollInfo?

    public var pixelSize: CGSize {
        CGSize(width: texture.width, height: texture.height)
    }

    public init(
        device: any MTLDevice,
        pointSize: CGSize,
        scale: CGFloat = 2.0,
        interactionHandler: XRPanelInteraction.Handler? = nil,
        @ViewBuilder content: () -> Content
    ) throws {
        let interaction = XRPanelInteraction(handler: interactionHandler)
        let host = XRSwiftUIHost(
            pointSize: pointSize,
            scale: scale,
            content: content()
        )
        let image = try host.renderImage()
        let texture = try Self.makeTexture(device: device, image: image)

        self.device = device
        self.pointSize = pointSize
        self.scale = scale
        self.interaction = interaction
        self.host = host
        self.texture = texture
        self.scrollInfo = host.scrollInfo()

        interaction.setInternalHandler { [weak self, weak interaction] event in
            guard let self, let interaction else { return }

            self.host.handle(
                event,
                pointerPosition: interaction.pointerPosition
            )

            switch event {
            case let .pointerDown(button): self.pressedPointerButtons.insert(button)
            case let .pointerUp(button): self.pressedPointerButtons.remove(button)
            case .pointerMoved, .pointerMovedBy, .pointerExited:
                if !self.refreshesOnPointerMovement && self.pressedPointerButtons.isEmpty {
                    return
                }
            default: break
            }

            // A queued mouse/key event usually reaches AppKit after this XR frame
            // returns. One immediate refresh may therefore still see the old
            // SwiftUI state. Refresh a few consecutive frames so the first
            // post-dispatch state is captured without continuously rasterizing
            // an otherwise static panel.
            self.inputRefreshFramesRemaining = max(
                self.inputRefreshFramesRemaining,
                3
            )
        }
    }

    /// Forward a device-neutral interaction intent to this panel.
    public func send(_ event: XRPanelInteractionEvent) {
        interaction.send(event)
    }

    /// Mark the panel dirty because application state changed independently of
    /// panel input. This is useful for clocks, progress indicators and other
    /// model-driven SwiftUI content. The next `refreshIfNeeded()` call performs
    /// one rasterization; input events still request their short multi-frame
    /// refresh window for queued AppKit delivery.
    public func invalidate() {
        inputRefreshFramesRemaining = max(inputRefreshFramesRemaining, 1)
    }

    /// Refresh after AppKit input or app-driven invalidation may have changed the
    /// hosted SwiftUI hierarchy. Applications should call this once per XR frame
    /// before drawing the panel.
    /// Returns true when a rasterization was performed, for frame diagnostics.
    @discardableResult
    public func refreshIfNeeded() throws -> Bool {
        guard inputRefreshFramesRemaining > 0 else { return false }
        inputRefreshFramesRemaining -= 1
        try refresh()
        return true
    }

    /// Rasterize the hosted SwiftUI hierarchy again and update the existing
    /// Metal texture. Keeping the texture identity stable means renderers can
    /// retain it while SwiftUI state changes underneath.
    public func refresh() throws {
        let image = try host.renderImage()
        let width = image.width
        let height = image.height
        if bitmapContext?.width != width || bitmapContext?.height != height {
            bitmapContext = Self.makeBitmapContext(width: width, height: height)
        }
        guard let context = bitmapContext, let pixels = context.data else {
            throw XRSwiftUIPanelError.bitmapContextCreationFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        context.draw(image, in: bounds)
        if usesImmutableTextures || texture.width != width || texture.height != height {
            texture = try Self.emptyTexture(device: device, width: width, height: height)
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: context.bytesPerRow)
        scrollInfo = host.scrollInfo()
    }

    private static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    }

    private static func emptyTexture(device: any MTLDevice, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XRSwiftUIPanelError.textureCreationFailed
        }
        texture.label = "SwiftXR hosted SwiftUI panel"
        return texture
    }

    private static func makeTexture(device: any MTLDevice, image: CGImage) throws -> any MTLTexture {
        guard let context = makeBitmapContext(width: image.width, height: image.height),
              let pixels = context.data else { throw XRSwiftUIPanelError.bitmapContextCreationFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let texture = try emptyTexture(device: device, width: image.width, height: image.height)
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: context.bytesPerRow)
        return texture
    }

}

public extension XRMacPointerCapture {
    /// Capture the physical Mac mouse/trackpad as a virtual pointer for a hosted
    /// SwiftUI panel. The system cursor is hidden/disassociated; SwiftXR posts a
    /// separate event stream to the panel's off-screen AppKit window.
    convenience init<Content: View>(
        panel: XRSwiftUIPanel<Content>,
        movementScale: SIMD2<Float> = SIMD2(700, 500)
    ) {
        self.init(
            interaction: panel.interaction,
            movementScale: movementScale
        )
    }
}
