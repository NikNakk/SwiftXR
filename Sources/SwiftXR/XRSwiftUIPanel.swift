import CoreGraphics
import Metal
import MetalKit
import SwiftUI

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
    private let textureLoader: MTKTextureLoader
    private let host: XRSwiftUIHost<Content>

    // Queued AppKit events are dispatched after the XR frame callback returns.
    // Keep refreshing for a small number of frames after input so at least one
    // rasterization occurs after SwiftUI has applied the event's state change.
    // Continuous dragging naturally keeps this counter topped up.
    private var inputRefreshFramesRemaining = 0

    public let pointSize: CGSize
    public let scale: CGFloat

    /// Semantic panel-input endpoint for mouse capture, gamepads, ray pointers,
    /// future Sense-controller input, and other non-native pointer sources.
    public let interaction: XRPanelInteraction

    public private(set) var texture: any MTLTexture

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
        let textureLoader = MTKTextureLoader(device: device)
        let interaction = XRPanelInteraction(handler: interactionHandler)
        let host = XRSwiftUIHost(
            pointSize: pointSize,
            scale: scale,
            content: content()
        )
        let image = try host.renderImage()
        let texture = try Self.makeTexture(
            loader: textureLoader,
            image: image
        )

        self.device = device
        self.textureLoader = textureLoader
        self.pointSize = pointSize
        self.scale = scale
        self.interaction = interaction
        self.host = host
        self.texture = texture

        interaction.setInternalHandler { [weak self, weak interaction] event in
            guard let self, let interaction else { return }

            self.host.handle(
                event,
                pointerPosition: interaction.pointerPosition
            )

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
    public func refreshIfNeeded() throws {
        guard inputRefreshFramesRemaining > 0 else { return }
        inputRefreshFramesRemaining -= 1
        try refresh()
    }

    /// Rasterize the hosted SwiftUI hierarchy again and update the existing
    /// Metal texture. Keeping the texture identity stable means renderers can
    /// retain it while SwiftUI state changes underneath.
    public func refresh() throws {
        let image = try host.renderImage()
        let refreshed = try Self.makeTexture(
            loader: textureLoader,
            image: image
        )

        guard
            refreshed.width == texture.width,
            refreshed.height == texture.height,
            refreshed.pixelFormat == texture.pixelFormat
        else {
            texture = refreshed
            return
        }

        let bytesPerPixel = 4
        let bytesPerRow = refreshed.width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: bytesPerRow * refreshed.height
        )
        let region = MTLRegionMake2D(
            0,
            0,
            refreshed.width,
            refreshed.height
        )

        pixels.withUnsafeMutableBytes { storage in
            guard let baseAddress = storage.baseAddress else { return }
            refreshed.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }

        pixels.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
    }

    private static func makeTexture(
        loader: MTKTextureLoader,
        image: CGImage
    ) throws -> any MTLTexture {
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
        ]

        let texture = try loader.newTexture(
            cgImage: image,
            options: options
        )
        texture.label = "SwiftXR hosted SwiftUI panel"
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
