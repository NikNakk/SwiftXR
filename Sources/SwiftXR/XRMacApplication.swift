import AppKit

/// AppKit application base class used by SwiftXR macOS applications that want
/// native mouse/trackpad interaction with off-screen SwiftUI panels.
///
/// The important interception point is `nextEvent(...)`, rather than an
/// `NSEvent` local monitor. AppKit controls may run nested tracking loops (for
/// example while dragging a Slider) and consume events directly from
/// `nextEvent`, bypassing local monitors. Transforming the event here lets those
/// controls see an ordinary mouseDown -> dragged -> mouseUp stream addressed to
/// the off-screen hosting window.
///
/// Swift Package clients should normally declare a trivial application-local
/// subclass and use that subclass as `NSPrincipalClass`. Keeping the principal
/// class in the app executable makes Objective-C runtime discovery deterministic
/// during AppKit's very early application-singleton creation.
@MainActor
@objc(XRMacApplication)
open class XRMacApplication: NSApplication {
    typealias EventTransformer = (NSEvent) -> NSEvent?

    var swiftXREventTransformer: EventTransformer?

    open override func nextEvent(
        matching mask: NSEvent.EventTypeMask,
        until expiration: Date?,
        inMode mode: RunLoop.Mode,
        dequeue deqFlag: Bool
    ) -> NSEvent? {
        // Peeking must not mutate SwiftXR pointer state or consume an event.
        guard deqFlag else {
            return super.nextEvent(
                matching: mask,
                until: expiration,
                inMode: mode,
                dequeue: false
            )
        }

        while true {
            guard let event = super.nextEvent(
                matching: mask,
                until: expiration,
                inMode: mode,
                dequeue: true
            ) else {
                return nil
            }

            guard let transformer = swiftXREventTransformer else {
                return event
            }

            if let transformed = transformer(event) {
                return transformed
            }

            // A nil transformed event means SwiftXR consumed it. Continue until
            // we have an event for AppKit or the original request times out.
        }
    }
}
