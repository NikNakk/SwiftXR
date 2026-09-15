import AppKit
import CoreGraphics
import simd

public enum XRMacPointerCaptureError: Error, CustomStringConvertible {
    case applicationNotActive
    case nativeEventRoutingUnavailable
    case mouseCursorDisassociationFailed(CGError)

    public var description: String {
        switch self {
        case .applicationNotActive:
            return "SwiftXR pointer capture requires a running, active foreground macOS application"
        case .nativeEventRoutingUnavailable:
            return "Native SwiftXR mouse routing requires XRMacApplication as the AppKit principal class"
        case let .mouseCursorDisassociationFailed(error):
            return "Could not disassociate the macOS mouse from the system cursor (CGError \(error.rawValue))"
        }
    }
}

@MainActor
private final class XRPointerCaptureWindow: NSWindow {
    // These windows exist only to keep physical pointer events inside the active
    // SwiftXR process. They must never steal key/main status from the hidden
    // NSHostingView window that is the true AppKit interaction target.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Exclusive mouse/trackpad capture for an XR panel on macOS.
///
/// In the native SwiftUI path, mouse events are transformed in
/// `XRMacApplication.nextEvent(...)`, before AppKit controls can enter nested
/// tracking loops. This is essential for controls such as Slider: local event
/// monitors are bypassed by nested control tracking.
@MainActor
public final class XRMacPointerCapture: NSObject {
    typealias NativeEventTransformer = (NSEvent, SIMD2<Float>) -> NSEvent?

    public let interaction: XRPanelInteraction

    /// Number of physical pointer delta units required to cross the panel.
    /// Larger values make the virtual XR pointer less sensitive.
    public var movementScale: SIMD2<Float>

    public private(set) var escapeRequested = false
    public private(set) var isCaptureRequested = false
    public private(set) var isCaptured = false

    private let nativeEventTransformer: NativeEventTransformer?
    private let nativeCapturePreparation: (() -> Void)?

    private var eventMonitor: Any?
    private var captureWindows: [NSWindow] = []
    private var savedCursorPosition: CGPoint?
    private var cursorHidden = false
    private var usesNativeApplicationRouting = false

    /// Semantic pointer capture. This remains useful for applications that want
    /// to translate a macOS mouse into SwiftXR's device-neutral interaction API.
    /// For hosted SwiftUI, prefer `XRMacPointerCapture(panel:)`, which preserves
    /// native AppKit control tracking and hover behavior.
    public convenience init(
        interaction: XRPanelInteraction,
        movementScale: SIMD2<Float> = SIMD2(700, 500)
    ) {
        self.init(
            interaction: interaction,
            movementScale: movementScale,
            nativeEventTransformer: nil,
            nativeCapturePreparation: nil
        )
    }

    init(
        interaction: XRPanelInteraction,
        movementScale: SIMD2<Float>,
        nativeEventTransformer: NativeEventTransformer?,
        nativeCapturePreparation: (() -> Void)?
    ) {
        self.interaction = interaction
        self.movementScale = movementScale
        self.nativeEventTransformer = nativeEventTransformer
        self.nativeCapturePreparation = nativeCapturePreparation
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

        if nativeEventTransformer != nil,
           !(application is XRMacApplication) {
            throw XRMacPointerCaptureError.nativeEventRoutingUnavailable
        }

        escapeRequested = false
        isCaptureRequested = true

        if nativeEventTransformer != nil {
            interaction.setNativePointerPosition(SIMD2<Float>(0.5, 0.5))
            nativeCapturePreparation?()
        } else {
            interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
        }

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

        nativeCapturePreparation?()
        savedCursorPosition = CGEvent(source: nil)?.location
        createCaptureWindows()

        let result = CGAssociateMouseAndMouseCursorPosition(0)
        guard result == .success else {
            destroyCaptureWindows()
            throw XRMacPointerCaptureError.mouseCursorDisassociationFailed(result)
        }

        NSCursor.hide()
        cursorHidden = true

        if nativeEventTransformer != nil {
            try installNativeApplicationRouting()
        } else {
            installSemanticEventMonitor()
        }

        isCaptured = true
    }

    private func releasePhysicalCapture(restoreCursor: Bool) {
        if usesNativeApplicationRouting,
           let application = NSApplication.shared as? XRMacApplication {
            application.swiftXREventTransformer = nil
            usesNativeApplicationRouting = false
        }

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        if isCaptured || cursorHidden {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        }

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
    }

    private func destroyCaptureWindows() {
        for window in captureWindows {
            window.orderOut(nil)
            window.close()
        }
        captureWindows.removeAll()
    }

    private func installNativeApplicationRouting() throws {
        guard
            let application = NSApplication.shared as? XRMacApplication,
            nativeEventTransformer != nil
        else {
            throw XRMacPointerCaptureError.nativeEventRoutingUnavailable
        }

        application.swiftXREventTransformer = { [weak self] event in
            guard let self else { return event }
            return self.transformNativeApplicationEvent(event)
        }
        usesNativeApplicationRouting = true
    }

    private func transformNativeApplicationEvent(_ event: NSEvent) -> NSEvent? {
        guard isCaptureRequested else { return event }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let xScale = max(movementScale.x, 1)
            let yScale = max(movementScale.y, 1)
            let position = interaction.moveNativePointer(
                by: SIMD2(
                    Float(event.deltaX) / xScale,
                    Float(event.deltaY) / yScale
                )
            )
            return nativeEventTransformer?(event, position)

        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .scrollWheel:
            let position = interaction.pointerPosition ?? SIMD2<Float>(0.5, 0.5)
            return nativeEventTransformer?(event, position)

        case .keyDown where event.keyCode == 53:
            escapeRequested = true
            stop()
            return nil

        default:
            return event
        }
    }

    private func installSemanticEventMonitor() {
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

            let shouldConsume: Bool = MainActor.assumeIsolated {
                guard self.isCaptured else { return false }
                return self.handleSemanticEvent(event)
            }

            return shouldConsume ? nil : event
        }
    }

    private func handleSemanticEvent(_ event: NSEvent) -> Bool {
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
