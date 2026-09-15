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
/// The SwiftUI hierarchy lives inside an off-screen `NSHostingView` with a real
/// AppKit responder chain. Device-neutral panel interaction events are translated
/// into AppKit mouse/key events so standard SwiftUI controls can respond.
@MainActor
public final class XRSwiftUIPanel<Content: View> {
    private let device: any MTLDevice
    private let textureLoader: MTKTextureLoader
    private let host: XRSwiftUIHost<Content>

    public let pointSize: CGSize
    public let scale: CGFloat

    /// Semantic panel-input endpoint. Applications map GameController, AppKit,
    /// engine input, or future OpenXR/Sense input into this endpoint.
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

            // Refresh after interaction so standard SwiftUI state changes become
            // visible in XR. MetalKit handles the image-origin conversion; the
            // resulting texture is simply swapped in on the next XR frame.
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

    /// Rasterize the hosted SwiftUI hierarchy again and replace its Metal
    /// texture. The renderer should read `texture` again before drawing.
    public func refresh() throws {
        let image = try host.renderImage()
        texture = try Self.makeTexture(
            loader: textureLoader,
            image: image
        )
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
