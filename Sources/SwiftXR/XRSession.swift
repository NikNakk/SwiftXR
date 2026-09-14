import COpenXR
import Metal

public enum XRSessionState: Int32, Sendable, Hashable, CustomStringConvertible {
    case unknown = 0
    case idle = 1
    case ready = 2
    case synchronized = 3
    case visible = 4
    case focused = 5
    case stopping = 6
    case lossPending = 7
    case exiting = 8

    public var description: String {
        switch self {
        case .unknown: return "unknown"
        case .idle: return "idle"
        case .ready: return "ready"
        case .synchronized: return "synchronized"
        case .visible: return "visible"
        case .focused: return "focused"
        case .stopping: return "stopping"
        case .lossPending: return "loss-pending"
        case .exiting: return "exiting"
        }
    }
}

public enum XRReferenceSpaceType: Sendable, Hashable {
    case local
}

public final class XRReferenceSpace {
    let handle: UnsafeMutableRawPointer

    public let type: XRReferenceSpaceType

    init(handle: UnsafeMutableRawPointer, type: XRReferenceSpaceType) {
        self.handle = handle
        self.type = type
    }
}

public final class XRSession {
    let handle: UnsafeMutableRawPointer
    let environmentBlendMode: Int32

    public let system: XRSystem
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public let localSpace: XRReferenceSpace

    public private(set) var state: XRSessionState = .idle
    public private(set) var isRunning = false
    public private(set) var shouldExit = false
    public private(set) var instanceLossPending = false

    init(system: XRSystem) throws {
        let device = try system.metalDevice()
        guard let commandQueue = device.makeCommandQueue() else {
            throw XRError.metalCommandQueueCreationFailed
        }

        let rawCommandQueue = Unmanaged
            .passUnretained(commandQueue as AnyObject)
            .toOpaque()

        var rawSession: UnsafeMutableRawPointer?
        try xrCheck(
            swiftxr_create_metal_session(
                system.instance.handle,
                system.systemID,
                rawCommandQueue,
                &rawSession
            ),
            "xrCreateSession(Metal)"
        )

        guard let sessionHandle = rawSession else {
            throw XRError.unexpectedNull("XrSession")
        }

        var rawLocalSpace: UnsafeMutableRawPointer?
        do {
            try xrCheck(
                swiftxr_create_local_space(sessionHandle, &rawLocalSpace),
                "xrCreateReferenceSpace(LOCAL)"
            )
        } catch {
            _ = swiftxr_destroy_session(sessionHandle)
            throw error
        }

        guard let localSpaceHandle = rawLocalSpace else {
            _ = swiftxr_destroy_session(sessionHandle)
            throw XRError.unexpectedNull("LOCAL XrSpace")
        }

        var blendMode: Int32 = 0
        do {
            try xrCheck(
                swiftxr_choose_environment_blend_mode(
                    system.instance.handle,
                    system.systemID,
                    &blendMode
                ),
                "xrEnumerateEnvironmentBlendModes"
            )
        } catch {
            _ = swiftxr_destroy_space(localSpaceHandle)
            _ = swiftxr_destroy_session(sessionHandle)
            throw error
        }

        self.system = system
        self.device = device
        self.commandQueue = commandQueue
        self.handle = sessionHandle
        self.environmentBlendMode = blendMode
        self.localSpace = XRReferenceSpace(
            handle: localSpaceHandle,
            type: .local
        )
    }

    deinit {
        _ = swiftxr_destroy_space(localSpace.handle)
        _ = swiftxr_destroy_session(handle)
    }

    /// Drain currently queued OpenXR events and apply the core session
    /// lifecycle transitions required by the OpenXR state machine.
    ///
    /// READY begins the primary stereo session. STOPPING ends it.
    /// EXITING, LOSS_PENDING, or an instance-loss event set `shouldExit`.
    /// The returned states are useful for logging or application callbacks.
    @discardableResult
    public func pollEvents() throws -> [XRSessionState] {
        var transitions: [XRSessionState] = []

        while true {
            var hadEvent: UInt32 = 0
            var hasState: UInt32 = 0
            var rawState: Int32 = 0
            var lostInstance: UInt32 = 0

            try xrCheck(
                swiftxr_poll_session_event(
                    system.instance.handle,
                    handle,
                    &hadEvent,
                    &hasState,
                    &rawState,
                    &lostInstance
                ),
                "xrPollEvent"
            )

            guard hadEvent != 0 else {
                break
            }

            if lostInstance != 0 {
                instanceLossPending = true
                shouldExit = true
            }

            guard hasState != 0 else {
                continue
            }

            let newState = XRSessionState(rawValue: rawState) ?? .unknown
            state = newState
            transitions.append(newState)

            switch newState {
            case .ready:
                if !isRunning {
                    try xrCheck(
                        swiftxr_begin_session(handle),
                        "xrBeginSession(PRIMARY_STEREO)"
                    )
                    isRunning = true
                }

            case .stopping:
                if isRunning {
                    try xrCheck(
                        swiftxr_end_session(handle),
                        "xrEndSession"
                    )
                    isRunning = false
                }

            case .lossPending, .exiting:
                shouldExit = true

            case .unknown, .idle, .synchronized, .visible, .focused:
                break
            }
        }

        return transitions
    }

    /// Ask the runtime to drive a running session through STOPPING to EXITING.
    public func requestExit() throws {
        try xrCheck(
            swiftxr_request_exit_session(handle),
            "xrRequestExitSession"
        )
    }
}
