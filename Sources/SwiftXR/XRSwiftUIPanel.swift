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
            return "SwiftUI ImageRenderer did not produce a CGImage"
        case .bitmapContextCreationFailed:
            return "Could not create the Core Graphics bitmap context for the SwiftUI panel"
        case .textureCreationFailed:
            return "Could not create the Metal texture for the SwiftUI panel"
        }
    }
}

/// A display-only SwiftUI surface rasterized into a shader-readable Metal texture.
///
/// The SwiftUI hierarchy is rendered only when the panel is created or `refresh()`
/// is called. The resulting texture can then be reused on every XR frame without
/// re-running SwiftUI layout/rasterization at headset refresh rate.
@MainActor
public final class XRSwiftUIPanel<Content: View> {
    private let device: any MTLDevice
    private let renderer: ImageRenderer<Content>

    public let pointSize: CGSize
    public let scale: CGFloat

    public private(set) var texture: any MTLTexture

    public var pixelSize: CGSize {
        CGSize(width: texture.width, height: texture.height)
    }

    public init(
        device: any MTLDevice,
        pointSize: CGSize,
        scale: CGFloat = 2.0,
        @ViewBuilder content: () -> Content
    ) throws {
        self.device = device
        self.pointSize = pointSize
        self.scale = scale

        let renderer = ImageRenderer(content: content())
        renderer.proposedSize = ProposedViewSize(
            width: pointSize.width,
            height: pointSize.height
        )
        renderer.scale = scale
        renderer.isOpaque = false
        self.renderer = renderer

        guard let cgImage = renderer.cgImage else {
            throw XRSwiftUIPanelError.imageRenderingFailed
        }

        self.texture = try Self.makeTexture(
            device: device,
            image: cgImage
        )
    }

    /// Rasterize the panel's current SwiftUI content again and update its texture.
    ///
    /// For mostly-static panels this need only be called when the SwiftUI content
    /// changes, rather than once per XR frame.
    public func refresh() throws {
        guard let cgImage = renderer.cgImage else {
            throw XRSwiftUIPanelError.imageRenderingFailed
        }

        if texture.width != cgImage.width || texture.height != cgImage.height {
            texture = try Self.makeTexture(device: device, image: cgImage)
            return
        }

        try Self.upload(image: cgImage, to: texture)
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
        texture.label = "SwiftXR SwiftUI panel"

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

            // Core Graphics and Metal use opposite vertical image conventions for
            // this bitmap upload path, so write the raster top-to-bottom for Metal.
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
