import AppKit
import CoreGraphics
import simd

public enum XRMacPointerCaptureError: Error, CustomStringConvertible {
    case mouseCursorDisassociationFailed(CGError)

    public var description: String {
        switch self {
        case let .mouseCursorDisassociationFailed(error):
            return "Could not disassociate the macOS mouse from the system cursor (CGError \(error.rawValue))"
        }
    }
}

/// Exclusive mouse/trackpad capture for an XR panel on macOS.
///
/// While capture is active SwiftXR:
/// - makes the process a foreground AppKit application,
/// - places transparent input windows over the attached Mac displays,
/// - hides and disassociates the system cursor from the pointing device,
/// - consumes mouse/button/scroll events before normal AppKit dispatch, and
/// - forwards relative input to `XRPanelInteraction`.
///
/// Capture is suspended automatically while the application is inactive and is
/// reacquired when it becomes active again. `stop()` always reconnects and
/// restores the system cursor to the position it occupied before capture.
@MainActor
public final class XRMacPointerCapture {
    public let interaction: XRPanelInteraction

    /// Number of physical pointer delta units required to cross the panel.
    /// Larger values make the virtual XR pointer less sensitive.
    public var movementScale: SIMD2<Float>

    /// Set when Escape is pressed while captured. The sample uses this as a
    /// convenient request to leave XR; applications may simply clear it.
    public private(set) var escapeRequested = false

    public private(set) var isCaptureRequested = false
    public private(set) var isCaptured = false

    private var eventMonitor: Any?
    private var activationObservers: [NSObjectProtocol] = []
    private var captureWindows: [NSWindow] = []
    private var savedCursorPosition: CGPoint?
    private var cursorHidden = false

    public init(
        interaction: XRPanelInteraction,
        movementScale: SIMD2<Float> = SIMD2(700, 500)
    ) {
        self.interaction = interaction
        self.movementScale = movementScale

        let center = NotificationCenter.default
        activationObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.releasePhysicalCapture(restoreCursor: true)
                }
            }
        )
        activationObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCaptureRequested else { return }
                    try? self.acquirePhysicalCapture()
                }
            }
        )
    }

    deinit {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }

        for window in captureWindows {
            window.orderOut(nil)
        }

        if isCaptured {
            CGAssociateMouseAndMouseCursorPosition(1)
            if cursorHidden {
                NSCursor.unhide()
            }
            if let savedCursorPosition {
                CGWarpMouseCursorPosition(savedCursorPosition)
            }
        }
    }

    /// Activate the application and begin exclusive relative-pointer capture.
    public func start() throws {
        guard !isCaptureRequested else { return }

        escapeRequested = false
        isCaptureRequested = true
        interaction.movePointer(to: SIMD2(0.5, 0.5))

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)

        if application.isActive {
            try acquirePhysicalCapture()
        }
    }

    /// Stop capture and return the pointing device to normal macOS behavior.
    public func stop() {
        isCaptureRequested = false
        releasePhysicalCapture(restoreCursor: true)
    }

    public func clearEscapeRequest() {
        escapeRequested = false
    }

    private func acquirePhysicalCapture() throws {
        guard isCaptureRequested, !isCaptured else { return }

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
            let window = NSWindow(
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
            window.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
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

            return MainActor.assumeIsolated {
                guard self.isCaptured else { return event }
                self.handle(event)
                return nil
            }
        }
    }

    private func handle(_ event: NSEvent) {
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

        case .leftMouseDown:
            interaction.pointerDown(.primary)
        case .leftMouseUp:
            interaction.pointerUp(.primary)
        case .rightMouseDown:
            interaction.pointerDown(.secondary)
        case .rightMouseUp:
            interaction.pointerUp(.secondary)

        case .scrollWheel:
            interaction.scroll(
                SIMD2(
                    Float(event.scrollingDeltaX) / 40,
                    Float(event.scrollingDeltaY) / 40
                )
            )

        case .keyDown where event.keyCode == 53:
            escapeRequested = true
            stop()

        default:
            break
        }
    }
}
