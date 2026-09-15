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

private final class XRPointerCaptureView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

/// Exclusive mouse/trackpad capture for an XR panel on macOS.
///
/// The real cursor is hidden and disassociated from physical mouse motion, just
/// as in the GAV PSVR2 player. Physical events land on invisible SwiftXR capture
/// windows; their deltas/buttons are converted to XRPanelInteraction events.
/// Hosted SwiftUI panels then post a second, synthetic AppKit event stream to
/// their off-screen NSHostingView window.
///
/// When the application is an XRMacApplication, translation happens from its
/// `nextEvent(...)` interception point. This is important because native AppKit
/// controls can enter nested event-tracking loops (for example Slider dragging)
/// that bypass NSEvent local monitors.
@MainActor
public final class XRMacPointerCapture: NSObject {
    public let interaction: XRPanelInteraction

    /// Physical mouse delta required to cross the virtual panel.
    public var movementScale: SIMD2<Float>

    public private(set) var escapeRequested = false
    public private(set) var isCaptureRequested = false
    public private(set) var isCaptured = false

    private var eventMonitor: Any?
    private var captureWindows: [NSWindow] = []
    private var savedCursorPosition: CGPoint?
    private var cursorHidden = false

    private weak var transformedApplication: XRMacApplication?
    private var previousEventTransformer: XRMacApplication.EventTransformer?

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

    public func start() throws {
        guard !isCaptureRequested else { return }

        let application = NSApplication.shared
        guard application.isRunning, application.isActive else {
            throw XRMacPointerCaptureError.applicationNotActive
        }

        escapeRequested = false
        isCaptureRequested = true
        interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))

        do {
            try acquirePhysicalCapture()
        } catch {
            isCaptureRequested = false
            releasePhysicalCapture(restoreCursor: true)
            throw error
        }
    }

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
        installEventInterception()

        let result = CGAssociateMouseAndMouseCursorPosition(0)
        guard result == .success else {
            uninstallEventInterception()
            destroyCaptureWindows()
            throw XRMacPointerCaptureError.mouseCursorDisassociationFailed(result)
        }

        NSCursor.hide()
        cursorHidden = true
        isCaptured = true
    }

    // MARK: - Physical-event interception

    private func installEventInterception() {
        guard eventMonitor == nil, transformedApplication == nil else { return }

        if let application = NSApplication.shared as? XRMacApplication {
            transformedApplication = application
            previousEventTransformer = application.swiftXREventTransformer
            let previous = previousEventTransformer

            application.swiftXREventTransformer = { [weak self] event in
                guard let self else {
                    return previous?(event) ?? event
                }

                return MainActor.assumeIsolated {
                    guard self.isCaptureWindowEvent(event) else {
                        return previous?(event) ?? event
                    }
                    return self.transformPhysicalEvent(event)
                }
            }
            return
        }

        // Fallback for applications that do not use XRMacApplication. This is
        // adequate for ordinary buttons/movement but cannot guarantee delivery
        // through nested AppKit tracking loops; SwiftXR's panel example uses the
        // XRMacApplication path above.
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

            return MainActor.assumeIsolated {
                guard self.isCaptureWindowEvent(event) else { return event }
                return self.transformPhysicalEvent(event)
            }
        }
    }

    private func uninstallEventInterception() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        if let application = transformedApplication {
            application.swiftXREventTransformer = previousEventTransformer
        }
        transformedApplication = nil
        previousEventTransformer = nil
    }

    private func isCaptureWindowEvent(_ event: NSEvent) -> Bool {
        captureWindows.contains { $0.windowNumber == event.windowNumber }
    }

    /// Convert a physical event into a semantic panel event and consume it.
    /// XRSwiftUIHost will queue the corresponding synthetic event addressed to
    /// its off-screen window. Returning nil here prevents the real event from
    /// reaching either the desktop or a native control's tracking loop.
    private func transformPhysicalEvent(_ event: NSEvent) -> NSEvent? {
        guard isCaptured || isCaptureRequested else { return event }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let xScale = max(movementScale.x, 1)
            let yScale = max(movementScale.y, 1)
            interaction.movePointer(
                by: SIMD2(
                    Float(event.deltaX) / xScale,
                    Float(event.deltaY) / yScale
                )
            )
            return nil

        case .leftMouseDown:
            interaction.pointerDown(.primary)
            return nil
        case .leftMouseUp:
            interaction.pointerUp(.primary)
            return nil
        case .rightMouseDown:
            interaction.pointerDown(.secondary)
            return nil
        case .rightMouseUp:
            interaction.pointerUp(.secondary)
            return nil

        case .otherMouseDown, .otherMouseUp:
            return nil

        case .scrollWheel:
            interaction.scroll(
                SIMD2(
                    Float(event.scrollingDeltaX) / 40,
                    Float(event.scrollingDeltaY) / 40
                )
            )
            return nil

        case .keyDown where event.keyCode == 53:
            escapeRequested = true
            stop()
            return nil

        case .keyDown:
            return event

        default:
            return event
        }
    }

    // MARK: - Invisible physical capture surface

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
            // Non-zero content alpha keeps the WindowServer surface eligible
            // for mouse hit-testing while remaining imperceptible.
            window.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.0001)
            window.alphaValue = 1
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
            window.contentView = XRPointerCaptureView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            window.orderFrontRegardless()
            return window
        }

        // Keep SwiftXR active so the physical event stream stays in this
        // application. The actual SwiftUI host remains a separate off-screen
        // window addressed by the synthetic events it creates.
        captureWindows.first?.makeKeyAndOrderFront(nil)
    }

    private func destroyCaptureWindows() {
        for window in captureWindows {
            window.orderOut(nil)
            window.close()
        }
        captureWindows.removeAll()
    }

    // MARK: - Release

    private func releasePhysicalCapture(restoreCursor: Bool) {
        uninstallEventInterception()

        if isCaptured || cursorHidden || !captureWindows.isEmpty {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        }

        // Restore while the cursor is still hidden so the user never sees the
        // private XR pointer position or the restoration warp.
        if restoreCursor, let savedCursorPosition {
            CGWarpMouseCursorPosition(savedCursorPosition)
            self.savedCursorPosition = nil
        }

        destroyCaptureWindows()

        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }

        isCaptured = false
    }
}
