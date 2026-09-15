import CoreGraphics
import Metal
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
/// Unlike a simple snapshot, the SwiftUI hierarchy lives inside an off-screen
/// `NSHostingView` with a real AppKit responder chain. Device-neutral panel
/// interaction events are translated into AppKit mouse/key events so standard
/// SwiftUI controls such as `Button`, `Toggle`, `Slider`, and `ScrollView` can
/// respond without the application reimplementing their behavior.
///
/// The Metal texture is updated after panel interaction and when `refresh()` is
/// called; it is still reused across XR frames and is not rerasterized at headset
/// refresh rate.
@MainActor
public final class XRSwiftUIPanel<Content: View> {
    private let device: any MTLDevice
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
        self.device = device
        self.pointSize = pointSize
        self.scale = scale

        let interaction = XRPanelInteraction(handler: interactionHandler)
        let host = XRSwiftUIHost(
            pointSize: pointSize,
            scale: scale,
            content: content()
        )
        let image = try host.renderImage()

        self.interaction = interaction
        self.host = host
        self.texture = try Self.makeTexture(device: device, image: image)

        interaction.setInternalHandler { [weak self, weak interaction] event in
            guard let self, let interaction else { return }

            self.host.handle(
                event,
                pointerPosition: interaction.pointerPosition
            )

            // SwiftUI model changes caused by a control action may be published
            // on the next main-loop turn. Refresh then rather than rasterizing
            // before SwiftUI has applied the state change.
            DispatchQueue.main.async { [weak self] in
                try? self?.refresh()
            }
        }
    }

    /// Forward a device-neutral interaction intent to this panel.
    public func send(_ event: XRPanelInteractionEvent) {
        interaction.send(event)
    }

    /// Rasterize the hosted SwiftUI hierarchy again and update the Metal texture.
    ///
    /// Call this after application-driven model changes that did not originate
    /// from `interaction`. Input events sent through the panel refresh it
    /// automatically on the next main-loop turn.
    public func refresh() throws {
        let image = try host.renderImage()

        if texture.width != image.width || texture.height != image.height {
            texture = try Self.makeTexture(device: device, image: image)
            return
        }

        try Self.upload(image: image, to: texture)
    }

    private static func makeTexture(
        device: any MTLDevice,
        image: CGImage
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XRSwiftUIPanelError.textureCreationFailed
        }
        texture.label = "SwiftXR hosted SwiftUI panel"

        try upload(image: image, to: texture)
        return texture
    }

    private static func upload(
        image: CGImage,
        to texture: any MTLTexture
    ) throws {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: bytesPerRow * height
        )

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue

        let drewImage = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }

        guard drewImage else {
            throw XRSwiftUIPanelError.bitmapContextCreationFailed
        }

        pixels.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
    }
}
