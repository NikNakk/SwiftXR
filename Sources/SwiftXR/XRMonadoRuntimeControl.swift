import Foundation
import Darwin

/// State reported by Monado for a connected OpenXR client.
public struct XRMonadoClientState: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let primaryApplication = Self(rawValue: 1 << 0)
    public static let sessionActive = Self(rawValue: 1 << 1)
    public static let sessionVisible = Self(rawValue: 1 << 2)
    public static let sessionFocused = Self(rawValue: 1 << 3)
    public static let sessionOverlay = Self(rawValue: 1 << 4)
    public static let posesBlocked = Self(rawValue: 1 << 6)
    public static let handTrackingBlocked = Self(rawValue: 1 << 7)
    public static let inputsBlocked = Self(rawValue: 1 << 8)
    public static let outputsBlocked = Self(rawValue: 1 << 9)
}

/// A client currently connected to the Monado service.
public struct XRMonadoClient: Identifiable, Sendable, Hashable {
    public let id: UInt32
    public let name: String
    public let state: XRMonadoClientState

    public init(id: UInt32, name: String, state: XRMonadoClientState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public enum XRMonadoRuntimeControlError: Error, LocalizedError, Sendable {
    case libraryUnavailable(String)
    case missingSymbol(String)
    case incompatibleAPIVersion(major: UInt32, minor: UInt32, patch: UInt32)
    case connectionFailed(Int32)
    case operationFailed(operation: String, result: Int32)

    public var errorDescription: String? {
        switch self {
        case let .libraryUnavailable(detail):
            return "Could not load libmonado: \(detail)"
        case let .missingSymbol(symbol):
            return "libmonado is missing required symbol \(symbol)"
        case let .incompatibleAPIVersion(major, minor, patch):
            return "Unsupported libmonado API version \(major).\(minor).\(patch); SwiftXR currently expects API major version 1"
        case let .connectionFailed(result):
            return "Could not connect to the Monado service (libmonado result \(result))"
        case let .operationFailed(operation, result):
            return "libmonado operation \(operation) failed with result \(result)"
        }
    }
}

/// Optional Monado-specific runtime management.
///
/// SwiftXR loads libmonado dynamically so applications using SwiftXR remain
/// buildable and usable with non-Monado OpenXR runtimes. The default loader
/// searches the normal dynamic-loader path plus common Homebrew/local install
/// locations. Set `SWIFTXR_LIBMONADO_PATH` to override the library location.
///
/// The underlying libmonado connection is not intended for concurrent access;
/// callers should serialize calls to an instance of this class.
public final class XRMonadoRuntimeControl {
    public let apiVersion: (major: UInt32, minor: UInt32, patch: UInt32)

    private let api: MonadoAPI
    private let root: OpaquePointer

    public init(libraryPath: String? = nil) throws {
        let api = try MonadoAPI(libraryPath: libraryPath)

        var major: UInt32 = 0
        var minor: UInt32 = 0
        var patch: UInt32 = 0
        api.apiGetVersion(&major, &minor, &patch)

        guard major == 1 else {
            throw XRMonadoRuntimeControlError.incompatibleAPIVersion(
                major: major,
                minor: minor,
                patch: patch
            )
        }

        var root: OpaquePointer?
        let result = api.rootCreate(&root)
        guard result >= 0, let root else {
            throw XRMonadoRuntimeControlError.connectionFailed(result)
        }

        self.api = api
        self.root = root
        self.apiVersion = (major, minor, patch)
    }

    deinit {
        var root: OpaquePointer? = root
        api.rootDestroy(&root)
    }

    /// Refresh Monado's cached client list and return a typed snapshot.
    public func refreshClients() throws -> [XRMonadoClient] {
        try check(api.rootUpdateClientList(root), operation: "mnd_root_update_client_list")

        var count: UInt32 = 0
        try check(
            api.rootGetNumberClients(root, &count),
            operation: "mnd_root_get_number_clients"
        )

        var clients: [XRMonadoClient] = []
        clients.reserveCapacity(Int(count))

        for index in 0..<count {
            var clientID: UInt32 = 0
            try check(
                api.rootGetClientIDAtIndex(root, index, &clientID),
                operation: "mnd_root_get_client_id_at_index"
            )

            var namePointer: UnsafePointer<CChar>?
            try check(
                api.rootGetClientName(root, clientID, &namePointer),
                operation: "mnd_root_get_client_name"
            )
            let name = namePointer.map { String(cString: $0) } ?? ""

            var rawState: UInt32 = 0
            try check(
                api.rootGetClientState(root, clientID, &rawState),
                operation: "mnd_root_get_client_state"
            )

            clients.append(
                XRMonadoClient(
                    id: clientID,
                    name: name,
                    state: XRMonadoClientState(rawValue: rawState)
                )
            )
        }

        return clients
    }

    /// Make the selected Monado client the primary application.
    public func setPrimary(clientID: UInt32) throws {
        try refreshClientListForMutation()
        try check(
            api.rootSetClientPrimary(root, clientID),
            operation: "mnd_root_set_client_primary"
        )
    }

    /// Give the selected Monado client input/session focus.
    public func setFocused(clientID: UInt32) throws {
        try refreshClientListForMutation()
        try check(
            api.rootSetClientFocused(root, clientID),
            operation: "mnd_root_set_client_focused"
        )
    }

    private func refreshClientListForMutation() throws {
        try check(api.rootUpdateClientList(root), operation: "mnd_root_update_client_list")
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result >= 0 else {
            throw XRMonadoRuntimeControlError.operationFailed(
                operation: operation,
                result: result
            )
        }
    }
}

private final class MonadoAPI {
    typealias APIGetVersion = @convention(c) (
        UnsafeMutablePointer<UInt32>,
        UnsafeMutablePointer<UInt32>,
        UnsafeMutablePointer<UInt32>
    ) -> Void
    typealias RootCreate = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias RootDestroy = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Void
    typealias RootUpdateClientList = @convention(c) (OpaquePointer) -> Int32
    typealias RootGetNumberClients = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt32>) -> Int32
    typealias RootGetClientIDAtIndex = @convention(c) (
        OpaquePointer,
        UInt32,
        UnsafeMutablePointer<UInt32>
    ) -> Int32
    typealias RootGetClientName = @convention(c) (
        OpaquePointer,
        UInt32,
        UnsafeMutablePointer<UnsafePointer<CChar>?>
    ) -> Int32
    typealias RootGetClientState = @convention(c) (
        OpaquePointer,
        UInt32,
        UnsafeMutablePointer<UInt32>
    ) -> Int32
    typealias RootSetClient = @convention(c) (OpaquePointer, UInt32) -> Int32

    let handle: UnsafeMutableRawPointer
    let apiGetVersion: APIGetVersion
    let rootCreate: RootCreate
    let rootDestroy: RootDestroy
    let rootUpdateClientList: RootUpdateClientList
    let rootGetNumberClients: RootGetNumberClients
    let rootGetClientIDAtIndex: RootGetClientIDAtIndex
    let rootGetClientName: RootGetClientName
    let rootGetClientState: RootGetClientState
    let rootSetClientPrimary: RootSetClient
    let rootSetClientFocused: RootSetClient

    init(libraryPath: String?) throws {
        let candidates = Self.libraryCandidates(explicitPath: libraryPath)
        var errors: [String] = []
        var openedHandle: UnsafeMutableRawPointer?

        for candidate in candidates {
            if let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) {
                openedHandle = handle
                break
            }
            if let error = dlerror() {
                errors.append("\(candidate): \(String(cString: error))")
            }
        }

        guard let handle = openedHandle else {
            let detail = errors.isEmpty
                ? "no candidate library could be opened"
                : errors.joined(separator: "; ")
            throw XRMonadoRuntimeControlError.libraryUnavailable(detail)
        }

        do {
            apiGetVersion = try Self.loadSymbol(handle, "mnd_api_get_version", as: APIGetVersion.self)
            rootCreate = try Self.loadSymbol(handle, "mnd_root_create", as: RootCreate.self)
            rootDestroy = try Self.loadSymbol(handle, "mnd_root_destroy", as: RootDestroy.self)
            rootUpdateClientList = try Self.loadSymbol(
                handle,
                "mnd_root_update_client_list",
                as: RootUpdateClientList.self
            )
            rootGetNumberClients = try Self.loadSymbol(
                handle,
                "mnd_root_get_number_clients",
                as: RootGetNumberClients.self
            )
            rootGetClientIDAtIndex = try Self.loadSymbol(
                handle,
                "mnd_root_get_client_id_at_index",
                as: RootGetClientIDAtIndex.self
            )
            rootGetClientName = try Self.loadSymbol(
                handle,
                "mnd_root_get_client_name",
                as: RootGetClientName.self
            )
            rootGetClientState = try Self.loadSymbol(
                handle,
                "mnd_root_get_client_state",
                as: RootGetClientState.self
            )
            rootSetClientPrimary = try Self.loadSymbol(
                handle,
                "mnd_root_set_client_primary",
                as: RootSetClient.self
            )
            rootSetClientFocused = try Self.loadSymbol(
                handle,
                "mnd_root_set_client_focused",
                as: RootSetClient.self
            )
            self.handle = handle
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        dlclose(handle)
    }

    private static func libraryCandidates(explicitPath: String?) -> [String] {
        if let explicitPath, !explicitPath.isEmpty {
            return [explicitPath]
        }

        if let environmentPath = ProcessInfo.processInfo.environment["SWIFTXR_LIBMONADO_PATH"],
           !environmentPath.isEmpty {
            return [environmentPath]
        }

        return [
            "libmonado.dylib",
            "/usr/local/lib/libmonado.dylib",
            "/opt/homebrew/lib/libmonado.dylib",
        ]
    }

    private static func loadSymbol<T>(
        _ handle: UnsafeMutableRawPointer,
        _ name: String,
        as type: T.Type
    ) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw XRMonadoRuntimeControlError.missingSymbol(name)
        }
        return unsafeBitCast(symbol, to: type)
    }
}
