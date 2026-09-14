import COpenXR
import Metal

public enum XRError: Error, CustomStringConvertible, Sendable {
    case openXR(operation: String, result: Int32)
    case requiredExtensionMissing(String)
    case unexpectedNull(String)
    case metalDeviceBridgeFailed
    case metalCommandQueueCreationFailed
    case sessionNotRunning

    public var description: String {
        switch self {
        case let .openXR(operation, result):
            return "\(operation) failed with XrResult \(result)"
        case let .requiredExtensionMissing(name):
            return "Required OpenXR extension is not available: \(name)"
        case let .unexpectedNull(value):
            return "OpenXR unexpectedly returned a null \(value)"
        case .metalDeviceBridgeFailed:
            return "The OpenXR runtime's Metal device could not be bridged to MTLDevice"
        case .metalCommandQueueCreationFailed:
            return "Could not create a Metal command queue from the OpenXR runtime's MTLDevice"
        case .sessionNotRunning:
            return "The OpenXR session is not running"
        }
    }
}

@inline(__always)
func xrCheck(_ result: XrResult, _ operation: String) throws {
    let value = swiftxr_result_value(result)
    if value < 0 {
        throw XRError.openXR(operation: operation, result: value)
    }
}

public struct XRExtension: Sendable, Hashable {
    public let name: String
    public let version: UInt32
}

public struct XRRuntimeCapabilities: Sendable {
    public let extensions: [XRExtension]

    public var supportsMetal: Bool {
        extensions.contains { $0.name == "XR_KHR_metal_enable" }
    }

    public func requireMetal() throws {
        guard supportsMetal else {
            throw XRError.requiredExtensionMissing("XR_KHR_metal_enable")
        }
    }
}

public enum XRRuntime {
    public static func capabilities() throws -> XRRuntimeCapabilities {
        var count: UInt32 = 0
        try xrCheck(
            xrEnumerateInstanceExtensionProperties(nil, 0, &count, nil),
            "xrEnumerateInstanceExtensionProperties(count)"
        )

        var properties = Array(
            repeating: swiftxr_make_extension_properties(),
            count: Int(count)
        )

        let result = properties.withUnsafeMutableBufferPointer { buffer in
            xrEnumerateInstanceExtensionProperties(
                nil,
                count,
                &count,
                buffer.baseAddress
            )
        }
        try xrCheck(result, "xrEnumerateInstanceExtensionProperties(values)")

        let extensions = properties.prefix(Int(count)).map { value -> XRExtension in
            var property = value
            let name = String(cString: swiftxr_extension_name(&property))
            return XRExtension(name: name, version: property.extensionVersion)
        }

        return XRRuntimeCapabilities(extensions: extensions)
    }
}

public struct XRVersion: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
        self.major = swiftxr_version_major(rawValue)
        self.minor = swiftxr_version_minor(rawValue)
        self.patch = swiftxr_version_patch(rawValue)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}

public struct XRRuntimeInfo: Sendable, Hashable {
    public let name: String
    public let version: XRVersion
}

public final class XRInstance {
    let handle: UnsafeMutableRawPointer

    public let runtime: XRRuntimeInfo

    public init(applicationName: String = "SwiftXR") throws {
        let capabilities = try XRRuntime.capabilities()
        try capabilities.requireMetal()

        var rawInstance: UnsafeMutableRawPointer?
        let createResult = applicationName.withCString { applicationNamePointer in
            swiftxr_create_instance(applicationNamePointer, &rawInstance)
        }
        try xrCheck(createResult, "xrCreateInstance")

        guard let handle = rawInstance else {
            throw XRError.unexpectedNull("XrInstance")
        }

        var properties = swiftxr_make_instance_properties()
        do {
            try xrCheck(
                swiftxr_get_instance_properties(handle, &properties),
                "xrGetInstanceProperties"
            )
        } catch {
            _ = swiftxr_destroy_instance(handle)
            throw error
        }

        let name = String(cString: swiftxr_runtime_name(&properties))
        let version = XRVersion(rawValue: swiftxr_runtime_version(&properties))

        self.handle = handle
        self.runtime = XRRuntimeInfo(name: name, version: version)
    }

    deinit {
        _ = swiftxr_destroy_instance(handle)
    }

    public func system() throws -> XRSystem {
        try XRSystem(instance: self)
    }
}

public struct XRSystemInfo: Sendable, Hashable {
    public let name: String
    public let vendorID: UInt32
    public let maxSwapchainImageWidth: UInt32
    public let maxSwapchainImageHeight: UInt32
    public let maxLayerCount: UInt32
    public let supportsOrientationTracking: Bool
    public let supportsPositionTracking: Bool
}

public final class XRSystem {
    let instance: XRInstance
    let systemID: UInt64

    public let info: XRSystemInfo

    init(instance: XRInstance) throws {
        var systemID: UInt64 = 0
        try xrCheck(
            swiftxr_get_hmd_system(instance.handle, &systemID),
            "xrGetSystem(HMD)"
        )

        var properties = swiftxr_make_system_properties()
        try xrCheck(
            swiftxr_get_system_properties(instance.handle, systemID, &properties),
            "xrGetSystemProperties"
        )

        self.instance = instance
        self.systemID = systemID
        self.info = XRSystemInfo(
            name: String(cString: swiftxr_system_name(&properties)),
            vendorID: swiftxr_system_vendor_id(&properties),
            maxSwapchainImageWidth: swiftxr_system_max_swapchain_width(&properties),
            maxSwapchainImageHeight: swiftxr_system_max_swapchain_height(&properties),
            maxLayerCount: swiftxr_system_max_layer_count(&properties),
            supportsOrientationTracking: swiftxr_system_orientation_tracking(&properties) != 0,
            supportsPositionTracking: swiftxr_system_position_tracking(&properties) != 0
        )
    }

    public func metalDevice() throws -> any MTLDevice {
        var rawDevice: UnsafeMutableRawPointer?
        try xrCheck(
            swiftxr_get_metal_device(instance.handle, systemID, &rawDevice),
            "xrGetMetalGraphicsRequirementsKHR"
        )

        guard let rawDevice else {
            throw XRError.unexpectedNull("Metal device")
        }

        let object = Unmanaged<AnyObject>
            .fromOpaque(UnsafeRawPointer(rawDevice))
            .takeUnretainedValue()

        guard let device = object as? any MTLDevice else {
            throw XRError.metalDeviceBridgeFailed
        }

        return device
    }

    public func makeSession() throws -> XRSession {
        try XRSession(system: self)
    }
}
