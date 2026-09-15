import AppKit
import CoreGraphics
import simd

public enum XRMacPointerCaptureError: Error, CustomStringConvertible {
    case applicationNotActive
    case mouseCursorDisassociationFailed(CGError)

    public var description: String {
        switch self {
        case .applicationNotActive:
            return "SwiftXR pointer capture requires a running, active foreground macOS application"
        case let .mouseCursorDisassociationFailed(error):
            return "Could not disassociate the macOS mouse from the system cursor (CGError \(error.rawValue))"
        }
    }
}

@MainActor
private final class XRPointerCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Exclusive mouse/trackpad capture for an XR panel on macOS.
///
/// This class deliberately assumes a real AppKit application lifecycle. It does
/// not try to promote a command-line process into a GUI application. Call
/// `start()` only after `NSApplication` is running and active.
///
/// While capture is active SwiftXR:
/// - places transparent input windows over the attached Mac displays,
/// - hides and disassociates the system cursor from the pointing device,
/// - consumes mouse/button/scroll events before normal AppKit dispatch, and
/// - forwards relative input to `XRPanelInteraction`.
///
/// Capture is suspended automatically while the application is inactive and is
/// reacquired when it becomes active again. `stop()` reconnects the pointing
/// device and restores the system cursor to the position it occupied before the
/// current capture interval.
@MainActor
public final class XRMacPointerCapture: NSObject {
    public let interaction: XRPanelInteraction

    /// Number of physical pointer delta units required to cross the panel.
    /// Larger values make the virtual XR pointer less sensitive.
    public var movementScale: SIMD2<Float>

    /// Set when Escape is pressed while captured. Applications can use this as
    /// a convenient request to leave XR.
    public private(set) var escapeRequested = false

    public private(set) var isCaptureRequested = false
    public private(set) var isCaptured = false

    private var eventMonitor: Any?
    private var captureWindows: [NSWindow] = []
    private var savedCursorPosition: CGPoint?
    private var cursorHidden = false

    public init(
        interaction: XRPanelInteraction,
        movementScale: SIMD2<Float> = SIMD2(700, 500)
    ) {
        self.interaction = interaction
        self.movementScale = movementScale
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Begin exclusive relative-pointer capture.
    ///
    /// The enclosing process must already be a running, active AppKit app. This
    /// requirement is intentional: modern macOS treats activation as a
    /// user-intent decision, so SwiftXR should not silently attempt to steal it.
    public func start() throws {
        guard !isCaptureRequested else { return }

        let application = NSApplication.shared
        guard application.isRunning, application.isActive else {
            throw XRMacPointerCaptureError.applicationNotActive
        }

        escapeRequested = false
        isCaptureRequested = true
        interaction.movePointer(to: SIMD2(0.5, 0.5))
        try acquirePhysicalCapture()
    }

    /// Stop capture and return the pointing device to normal macOS behavior.
    ///
    /// Applications should pair every successful `start()` with `stop()`. Focus
    /// loss also releases the physical capture automatically.
    public func stop() {
        isCaptureRequested = false
        releasePhysicalCapture(restoreCursor: true)
    }

    public func clearEscapeRequest() {
        escapeRequested = false
    }

    @objc
    private func applicationDidResignActive() {
        releasePhysicalCapture(restoreCursor: true)
    }

    @objc
    private func applicationDidBecomeActive() {
        guard isCaptureRequested, !isCaptured else { return }
        try? acquirePhysicalCapture()
    }

    private func acquirePhysicalCapture() throws {
        guard isCaptureRequested, !isCaptured else { return }
        guard NSApplication.shared.isActive else {
            throw XRMacPointerCaptureError.applicationNotActive
        }

        savedCursorPosition = CGEvent(source: nil)?.location
        createCaptureWindows()

        let result = CGAssociateMouseAndMouseCursorPosition(0)
        guard result == .success else {
            destroyCaptureWindows()
            throw XRMacPointerCaptureError.mouseCursorDisassociationFailed(result)
        }

        NSCursor.hide()
        cursorHidden = true
        installEventMonitor()
        isCaptured = true
    }

    private func releasePhysicalCapture(restoreCursor: Bool) {
        guard isCaptured || eventMonitor != nil || !captureWindows.isEmpty else {
            return
        }

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        _ = CGAssociateMouseAndMouseCursorPosition(1)

        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }

        if restoreCursor, let savedCursorPosition {
            CGWarpMouseCursorPosition(savedCursorPosition)
        }

        destroyCaptureWindows()
        isCaptured = false
    }

    private func createCaptureWindows() {
        destroyCaptureWindows()

        captureWindows = NSScreen.screens.map { screen in
            let window = XRPointerCaptureWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle,
            ]
            window.contentView = NSView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            window.orderFrontRegardless()
            return window
        }

        captureWindows.first?.makeKeyAndOrderFront(nil)
    }

    private func destroyCaptureWindows() {
        for window in captureWindows {
            window.orderOut(nil)
            window.close()
        }
        captureWindows.removeAll()
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel,
            .keyDown,
        ]

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }

            // NSEvent is explicitly non-Sendable. Keep it outside the isolated
            // result boundary: only the Bool decision crosses out of
            // `assumeIsolated`, then return the original event here.
            let shouldConsume: Bool = MainActor.assumeIsolated {
                guard self.isCaptured else { return false }
                return self.handle(event)
            }

            return shouldConsume ? nil : event
        }
    }

    /// Returns true when the original AppKit event should be consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let xScale = max(movementScale.x, 1)
            let yScale = max(movementScale.y, 1)
            interaction.movePointer(
                by: SIMD2(
                    Float(event.deltaX) / xScale,
                    -Float(event.deltaY) / yScale
                )
            )
            return true

        case .leftMouseDown:
            interaction.pointerDown(.primary)
            return true
        case .leftMouseUp:
            interaction.pointerUp(.primary)
            return true
        case .rightMouseDown:
            interaction.pointerDown(.secondary)
            return true
        case .rightMouseUp:
            interaction.pointerUp(.secondary)
            return true

        case .otherMouseDown, .otherMouseUp:
            return true

        case .scrollWheel:
            interaction.scroll(
                SIMD2(
                    Float(event.scrollingDeltaX) / 40,
                    Float(event.scrollingDeltaY) / 40
                )
            )
            return true

        case .keyDown where event.keyCode == 53:
            escapeRequested = true
            stop()
            return true

        case .keyDown:
            return false

        default:
            return true
        }
    }
}
