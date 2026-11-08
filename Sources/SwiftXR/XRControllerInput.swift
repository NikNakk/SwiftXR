import COpenXR
import simd

/// One hand's OpenXR actions. An active hand can temporarily lack a valid pose
/// (for example during an occlusion); callers should hide its ray in that case.
public struct XRControllerHandState: Sendable {
    public let isActive: Bool
    public let aimPose: XRPose?
    public let select: Bool
    /// Cross on the right Sense / A on Touch (Square / X on the left).
    public let primaryButton: Bool
    public let grip: Bool
    public let back: Bool
    /// The application menu button: Create on PS VR2 Sense, the left menu
    /// button on Touch.
    public let menu: Bool
    /// The system "home" button: PS on either Sense controller, the right
    /// system button on Touch where the runtime allows it. Shells use it to
    /// return to their home view.
    public let home: Bool
    public let recenter: Bool
    public let thumbstick: SIMD2<Float>
}

public struct XRControllerState: Sendable {
    public let isFocused: Bool
    public let left: XRControllerHandState
    public let right: XRControllerHandState
}

/// OpenXR action input for tracked panel pointers. Create once before beginning
/// the session: OpenXR permits attaching action sets only once per session.
/// Retains the session so action spaces are destroyed before the session.
public final class XRControllerInput {
    private let session: XRSession
    private let handle: UnsafeMutablePointer<SwiftXRControllerInput>

    public init(session: XRSession) throws {
        var handle: UnsafeMutablePointer<SwiftXRControllerInput>?
        let extensions = session.system.instance.enabledInputExtensions
        try xrCheck(swiftxr_create_controller_input(
            session.system.instance.handle, session.handle,
            extensions.contains("XR_MNDX_psvr2_interaction") ? 1 : 0,
            extensions.contains("XR_KHR_generic_controller") ? 1 : 0,
            &handle
        ), "create/attach controller actions")
        guard let handle else { throw XRError.unexpectedNull("controller input") }
        self.session = session
        self.handle = handle
    }

    deinit { swiftxr_destroy_controller_input(handle) }

    /// Sync actions and locate aim poses at this frame's predicted display time,
    /// in the same LOCAL reference space as XRFrame.views.
    public func poll(predictedDisplayTime: Int64) throws -> XRControllerState {
        var state = SwiftXRControllerState()
        try xrCheck(swiftxr_poll_controller_input(
            handle, session.localSpace.handle, predictedDisplayTime, &state
        ), "sync/locate controller input")
        return XRControllerState(isFocused: state.focused != 0,
                                 left: Self.hand(state.left), right: Self.hand(state.right))
    }

    private static func hand(_ hand: SwiftXRHandInput) -> XRControllerHandState {
        let p = hand.pose
        let pose = hand.pose_valid != 0 ? XRPose(
            position: XRVector3(x: p.position.x, y: p.position.y, z: p.position.z),
            orientation: XRQuaternion(x: p.orientation.x, y: p.orientation.y,
                                      z: p.orientation.z, w: p.orientation.w)
        ) : nil
        return XRControllerHandState(isActive: hand.active != 0, aimPose: pose,
                                     select: hand.select != 0,
                                     primaryButton: hand.primary != 0, grip: hand.grip != 0, back: hand.back != 0,
                                     menu: hand.menu != 0, home: hand.home != 0, recenter: hand.recenter != 0,
                                     thumbstick: SIMD2(hand.x, hand.y))
    }
}
