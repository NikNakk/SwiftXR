import simd

public enum XRPanelNavigationDirection: Sendable, Hashable {
    case up
    case down
    case left
    case right
    case next
    case previous
}

public enum XRPanelPointerButton: Sendable, Hashable {
    case primary
    case secondary
}

/// Device-neutral input understood by a SwiftXR UI panel.
///
/// Applications remain free to use GameController, AppKit, an engine input
/// system, or OpenXR actions directly. They translate those device-specific
/// events into these semantic panel operations only when they want to interact
/// with a SwiftXR panel.
public enum XRPanelInteractionEvent: Sendable, Hashable {
    case navigate(XRPanelNavigationDirection)
    case select
    case back

    /// Place the virtual pointer at normalized panel coordinates, where
    /// (0, 0) is the top-left and (1, 1) is the bottom-right.
    case pointerMoved(to: SIMD2<Float>)

    /// Move the virtual pointer by a normalized panel-space delta.
    case pointerMovedBy(SIMD2<Float>)

    case pointerExited
    case pointerDown(XRPanelPointerButton)
    case pointerUp(XRPanelPointerButton)

    /// Scroll in application-defined logical units. Conventionally positive Y
    /// means upward/previous and negative Y means downward/next.
    case scroll(SIMD2<Float>)
}

/// Semantic interaction endpoint owned by an XR panel.
///
/// It deliberately does not wrap GameController/AppKit/OpenXR hardware input.
/// Instead, applications forward only panel-relevant intents here. This keeps
/// game input in the game's existing input architecture while giving SwiftXR a
/// stable panel interaction boundary that can later accept Sense-controller ray
/// hits without changing application UI code.
@MainActor
public final class XRPanelInteraction {
    public typealias Handler = (XRPanelInteractionEvent) -> Void

    /// Current normalized virtual-cursor position, or nil when no pointer is on
    /// the panel. SwiftXR maintains this for relative mouse-style input.
    public private(set) var pointerPosition: SIMD2<Float>?

    /// Optional application observer called after SwiftXR has dispatched the
    /// event to the panel's hosted UI surface.
    public var handler: Handler?

    private var internalHandler: Handler?

    public init(handler: Handler? = nil) {
        self.handler = handler
    }

    func setInternalHandler(_ handler: Handler?) {
        internalHandler = handler
    }

    public func send(_ event: XRPanelInteractionEvent) {
        switch event {
        case let .pointerMoved(position):
            pointerPosition = Self.clamped(position)

        case let .pointerMovedBy(delta):
            let origin = pointerPosition ?? SIMD2<Float>(0.5, 0.5)
            pointerPosition = Self.clamped(origin + delta)

        case .pointerExited:
            pointerPosition = nil

        case .navigate, .select, .back,
             .pointerDown, .pointerUp, .scroll:
            break
        }

        internalHandler?(event)
        handler?(event)
    }

    public func navigate(_ direction: XRPanelNavigationDirection) {
        send(.navigate(direction))
    }

    public func select() {
        send(.select)
    }

    public func back() {
        send(.back)
    }

    public func movePointer(to position: SIMD2<Float>) {
        send(.pointerMoved(to: position))
    }

    public func movePointer(by delta: SIMD2<Float>) {
        send(.pointerMovedBy(delta))
    }

    public func scroll(_ delta: SIMD2<Float>) {
        send(.scroll(delta))
    }

    public func pointerDown(_ button: XRPanelPointerButton = .primary) {
        send(.pointerDown(button))
    }

    public func pointerUp(_ button: XRPanelPointerButton = .primary) {
        send(.pointerUp(button))
    }

    private static func clamped(_ value: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(
            min(max(value.x, 0), 1),
            min(max(value.y, 0), 1)
        )
    }
}
