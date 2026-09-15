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
    // These windows exist only to swallow physical desktop clicks while the
    // real cursor is hidden/disassociated. They must never steal key/main state
    // from the off-screen SwiftUI host window receiving synthetic events.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class XRPointerCaptureView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

/// Exclusive mouse/trackpad capture for an XR panel on macOS.
///
/// This deliberately mirrors the physical side of the GAV PSVR2 player's input
/// model: the real cursor is hidden and disassociated from physical mouse
/// motion, while `CGGetLastMouseDelta()` drives a virtual cursor. Mouse-button
/// transitions are sampled from `NSEvent.pressedMouseButtons`.
///
/// Hosted SwiftUI panels translate the resulting `XRPanelInteraction` events
/// into a second, synthetic AppKit event stream addressed to their off-screen
/// NSHostingView window. Because polling is performed by the application's XR
/// frame callback, no custom `NSApplication` subclass is required. The frame
/// callback should continue running in AppKit's event-tracking run-loop mode so
/// Slider and other nested tracking loops still receive synthetic drag/up events.
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
    private var previousPressedMouseButtons = 0

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

        // Besides centering the XR cursor, this gives a hosted SwiftUI panel a
        // chance to make its off-screen AppKit window key before the non-key
        // physical capture overlays are installed.
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

    /// Poll the captured physical mouse and emit semantic panel events.
    ///
    /// Call this from the application's XR/frame callback. In particular, keep
    /// that callback scheduled in AppKit's event-tracking run-loop mode: a
    /// native Slider may run a nested tracking loop after receiving mouseDown,
    /// and polling here is what supplies the subsequent dragged/mouseUp events.
    public func poll() {
        guard isCaptured else { return }

        let currentButtons = NSEvent.pressedMouseButtons
        let previousButtons = previousPressedMouseButtons

        let primaryMask = 1 << 0
        let secondaryMask = 1 << 1

        let primaryWasDown = (previousButtons & primaryMask) != 0
        let primaryIsDown = (currentButtons & primaryMask) != 0
        let secondaryWasDown = (previousButtons & secondaryMask) != 0
        let secondaryIsDown = (currentButtons & secondaryMask) != 0

        // Press first, then movement, then release. If a press and physical
        // motion are observed in one frame, the move is therefore delivered as
        // a drag; if release follows movement, the final drag precedes mouseUp.
        if !primaryWasDown && primaryIsDown {
            interaction.pointerDown(.primary)
        }
        if !secondaryWasDown && secondaryIsDown {
            interaction.pointerDown(.secondary)
        }

        let delta = CGGetLastMouseDelta()
        let dx = delta.x
        let dy = delta.y

        if dx != 0 || dy != 0 {
            let xScale = max(movementScale.x, 1)
            let yScale = max(movementScale.y, 1)
            interaction.movePointer(
                by: SIMD2(
                    Float(dx) / xScale,
                    Float(dy) / yScale
                )
            )
        }

        if primaryWasDown && !primaryIsDown {
            interaction.pointerUp(.primary)
        }
        if secondaryWasDown && !secondaryIsDown {
            interaction.pointerUp(.secondary)
        }

        previousPressedMouseButtons = currentButtons
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
        previousPressedMouseButtons = NSEvent.pressedMouseButtons
        createCaptureWindows()
        installAuxiliaryEventMonitor()

        let result = CGAssociateMouseAndMouseCursorPosition(0)
        guard result == .success else {
            uninstallAuxiliaryEventMonitor()
            destroyCaptureWindows()
            throw XRMacPointerCaptureError.mouseCursorDisassociationFailed(result)
        }

        NSCursor.hide()
        cursorHidden = true
        isCaptured = true
    }

    // MARK: - Scroll / keyboard events

    /// Movement and button transitions are intentionally polled, not intercepted
    /// here. Scrolling has no equivalent button-state API, so a small local
    /// monitor forwards wheel events from the physical capture surface. Escape
    /// remains a convenient way to release/exit the demo.
    private func installAuxiliaryEventMonitor() {
        guard eventMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [
            .scrollWheel,
            .keyDown,
        ]

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }

            let shouldConsume: Bool = MainActor.assumeIsolated {
                guard self.isCaptured || self.isCaptureRequested else { return false }

                if event.type == .keyDown && event.keyCode == 53 {
                    self.escapeRequested = true
                    self.stop()
                    return true
                }

                if event.type == .scrollWheel,
                   self.isCaptureWindowEvent(event) {
                    self.interaction.scroll(
                        SIMD2(
                            Float(event.scrollingDeltaX) / 40,
                            Float(event.scrollingDeltaY) / 40
                        )
                    )
                    return true
                }

                return false
            }

            return shouldConsume ? nil : event
        }
    }

    private func uninstallAuxiliaryEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func isCaptureWindowEvent(_ event: NSEvent) -> Bool {
        captureWindows.contains { $0.windowNumber == event.windowNumber }
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
            window.acceptsMouseMovedEvents = false
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
        uninstallAuxiliaryEventMonitor()

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

        previousPressedMouseButtons = 0
        isCaptured = false
    }
}
