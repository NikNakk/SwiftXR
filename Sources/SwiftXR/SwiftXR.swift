import COpenXR

public enum XRError: Error, CustomStringConvertible, Sendable {
    case openXR(operation: String, result: Int32)
    case requiredExtensionMissing(String)

    public var description: String {
        switch self {
        case let .openXR(operation, result):
            return "\(operation) failed with XrResult \(result)"
        case let .requiredExtensionMissing(name):
            return "Required OpenXR extension is not available: \(name)"
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
