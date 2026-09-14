import COpenXR
import Metal

public enum XRSwapchainError: Error, CustomStringConvertible {
    case textureBridgeFailed(index: Int)
    case notStereoTexture(index: Int, type: MTLTextureType, arrayLength: Int)
    case imageIndexOutOfRange(UInt32)
    case commandBufferCreationFailed
    case belongsToDifferentSession

    public var description: String {
        switch self {
        case let .textureBridgeFailed(index):
            return "OpenXR swapchain image \(index) could not be bridged to MTLTexture"
        case let .notStereoTexture(index, type, arrayLength):
            return "OpenXR swapchain image \(index) is not a two-layer Metal array texture (type=\(type), arrayLength=\(arrayLength))"
        case let .imageIndexOutOfRange(index):
            return "OpenXR acquired swapchain image index \(index), which is outside the enumerated image array"
        case .commandBufferCreationFailed:
            return "Could not create a Metal command buffer for the OpenXR frame"
        case .belongsToDifferentSession:
            return "The OpenXR swapchain belongs to a different XRSession"
        }
    }
}

public struct XRViewConfiguration: Sendable, Hashable {
    public let leftWidth: UInt32
    public let leftHeight: UInt32
    public let rightWidth: UInt32
    public let rightHeight: UInt32
    public let recommendedSampleCount: UInt32

    public var commonWidth: UInt32 { max(leftWidth, rightWidth) }
    public var commonHeight: UInt32 { max(leftHeight, rightHeight) }
}

public final class XRSwapchain {
    let handle: UnsafeMutableRawPointer
    let session: XRSession
    let textures: [any MTLTexture]

    public let viewConfiguration: XRViewConfiguration
    public let width: UInt32
    public let height: UInt32
    public let format: Int64

    public var imageCount: Int { textures.count }
    public var pixelFormat: MTLPixelFormat { textures[0].pixelFormat }

    init(session: XRSession) throws {
        var configuration = SwiftXRViewConfigurationData()
        try xrCheck(
            swiftxr_get_stereo_view_configuration(
                session.system.instance.handle,
                session.system.systemID,
                &configuration
            ),
            "xrEnumerateViewConfigurationViews(PRIMARY_STEREO)"
        )

        let viewConfiguration = XRViewConfiguration(
            leftWidth: configuration.left_width,
            leftHeight: configuration.left_height,
            rightWidth: configuration.right_width,
            rightHeight: configuration.right_height,
            recommendedSampleCount: configuration.recommended_sample_count
        )

        var selectedFormat: Int64 = 0
        try xrCheck(
            swiftxr_choose_color_swapchain_format(
                session.handle,
                Int64(MTLPixelFormat.rgba8Unorm_srgb.rawValue),
                Int64(MTLPixelFormat.bgra8Unorm_srgb.rawValue),
                Int64(MTLPixelFormat.rgba8Unorm.rawValue),
                Int64(MTLPixelFormat.bgra8Unorm.rawValue),
                &selectedFormat
            ),
            "xrEnumerateSwapchainFormats(color)"
        )

        let width = viewConfiguration.commonWidth
        let height = viewConfiguration.commonHeight

        var rawSwapchain: UnsafeMutableRawPointer?
        try xrCheck(
            swiftxr_create_stereo_swapchain(
                session.handle,
                selectedFormat,
                width,
                height,
                &rawSwapchain
            ),
            "xrCreateSwapchain(stereo Metal array)"
        )

        guard let swapchainHandle = rawSwapchain else {
            throw XRError.unexpectedNull("XrSwapchain")
        }

        var rawImages = SwiftXRMetalSwapchainImages()
        do {
            try xrCheck(
                swiftxr_enumerate_metal_swapchain_images(
                    swapchainHandle,
                    &rawImages
                ),
                "xrEnumerateSwapchainImages(Metal)"
            )
        } catch {
            _ = swiftxr_destroy_swapchain(swapchainHandle)
            throw error
        }

        var textures: [any MTLTexture] = []
        textures.reserveCapacity(Int(rawImages.count))

        do {
            for index in 0..<Int(rawImages.count) {
                guard let rawTexture = swiftxr_metal_swapchain_texture(
                    &rawImages,
                    UInt32(index)
                ) else {
                    throw XRSwapchainError.textureBridgeFailed(index: index)
                }

                let object = Unmanaged<AnyObject>
                    .fromOpaque(UnsafeRawPointer(rawTexture))
                    .takeUnretainedValue()

                guard let texture = object as? any MTLTexture else {
                    throw XRSwapchainError.textureBridgeFailed(index: index)
                }

                guard texture.textureType == .type2DArray, texture.arrayLength >= 2 else {
                    throw XRSwapchainError.notStereoTexture(
                        index: index,
                        type: texture.textureType,
                        arrayLength: texture.arrayLength
                    )
                }

                textures.append(texture)
            }
        } catch {
            _ = swiftxr_destroy_swapchain(swapchainHandle)
            throw error
        }

        self.session = session
        self.handle = swapchainHandle
        self.textures = textures
        self.viewConfiguration = viewConfiguration
        self.width = width
        self.height = height
        self.format = selectedFormat
    }

    deinit {
        _ = swiftxr_destroy_swapchain(handle)
    }
}

extension XRSession {
    public func makeStereoSwapchain() throws -> XRSwapchain {
        try XRSwapchain(session: self)
    }
}
