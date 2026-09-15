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
/// The same `NSHostingView` supplies both the pixels shown in XR and, during
/// `XRMacPointerCapture(panel:)`, the real native AppKit interaction surface.
/// The macOS mouse therefore interacts with ordinary SwiftUI controls without
/// SwiftXR synthesising or retargeting mouse events.
@MainActor
public final class XRSwiftUIPanel<Content: View> {
    private let device: any MTLDevice
    private let textureLoader: MTKTextureLoader
    private let host: XRSwiftUIHost<Content>
    private var nativeInputNeedsRefresh = false

    public let pointSize: CGSize
    public let scale: CGFloat

    /// Semantic panel-input endpoint for gamepads, ray pointers, future Sense
    /// controller input, and other non-native pointer sources.
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

            try? self.refresh()

            DispatchQueue.main.async { [weak self] in
                try? self?.refresh()
            }
        }
    }

    /// Forward a device-neutral interaction intent to this panel.
    public func send(_ event: XRPanelInteractionEvent) {
        interaction.send(event)
    }

    /// Refresh only when native AppKit input has changed the hosted surface.
    /// Applications using `XRMacPointerCapture(panel:)` should call this once per
    /// XR frame before drawing the panel. It also samples the real system cursor
    /// so the XR software cursor continues to track during AppKit nested control
    /// tracking (for example while a Slider is being dragged).
    public func refreshIfNeeded() throws {
        if let position = host.realMousePointerPosition(),
           interaction.pointerPosition != position {
            interaction.setNativePointerPosition(position)
            nativeInputNeedsRefresh = true
        }

        guard nativeInputNeedsRefresh else { return }
        nativeInputNeedsRefresh = false
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

    // MARK: - Real macOS mouse integration

    func beginRealMacPointerCapture() {
        host.beginRealMouseCaptureSurface()
        nativeInputNeedsRefresh = true
    }

    func endRealMacPointerCapture() {
        host.endRealMouseCaptureSurface()
        nativeInputNeedsRefresh = true
    }

    func realMacPointerPosition() -> SIMD2<Float>? {
        host.realMousePointerPosition()
    }

    func invalidateRealMacInput() {
        nativeInputNeedsRefresh = true
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
    /// Capture the real macOS mouse/trackpad for a hosted SwiftUI panel.
    ///
    /// Unlike the device-neutral `init(interaction:)` path this does not
    /// disassociate the mouse or manufacture NSEvents. The actual NSHostingView
    /// becomes an effectively invisible desktop-sized key window and receives
    /// the ordinary AppKit mouse stream directly. This is the preferred macOS
    /// path for Buttons, Sliders, hover effects, scrolling, context menus and
    /// SwiftUI drag gestures.
    convenience init<Content: View>(
        panel: XRSwiftUIPanel<Content>,
        movementScale: SIMD2<Float> = SIMD2(700, 500)
    ) {
        self.init(
            interaction: panel.interaction,
            movementScale: movementScale,
            realSurfaceBegin: { [weak panel] in
                panel?.beginRealMacPointerCapture()
            },
            realSurfaceEnd: { [weak panel] in
                panel?.endRealMacPointerCapture()
            },
            realPointerProvider: { [weak panel] in
                panel?.realMacPointerPosition()
            },
            realInputInvalidation: { [weak panel] in
                panel?.invalidateRealMacInput()
            }
        )
    }
}
