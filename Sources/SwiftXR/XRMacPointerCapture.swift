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
/// There are two modes:
/// - `init(interaction:)` keeps the older device-neutral relative-pointer path,
///   disassociating the system cursor and translating deltas into SwiftXR events.
/// - `init(panel:)` (declared alongside XRSwiftUIPanel) keeps the real macOS
///   cursor associated and gives the actual hosted SwiftUI window the desktop as
///   its interaction surface. This preserves native Button, Slider, hover,
///   scrolling and drag semantics.
@MainActor
public final class XRMacPointerCapture: NSObject {
    public let interaction: XRPanelInteraction

    /// Number of physical pointer delta units required to cross the panel in the
    /// device-neutral relative-pointer mode. The real SwiftUI mouse path does not
    /// use this scale because AppKit maps the real desktop pointer itself.
    public var movementScale: SIMD2<Float>

    public private(set) var escapeRequested = false
    public private(set) var isCaptureRequested = false
    public private(set) var isCaptured = false

    private let realSurfaceBegin: (() -> Void)?
    private let realSurfaceEnd: (() -> Void)?
    private let realPointerProvider: (() -> SIMD2<Float>?)?
    private let realInputInvalidation: (() -> Void)?

    private var eventMonitor: Any?
    private var captureWindows: [NSWindow] = []
    private var savedCursorPosition: CGPoint?
    private var cursorHidden = false

    /// Device-neutral relative mouse capture. For a hosted SwiftUI panel prefer
    /// `XRMacPointerCapture(panel:)` so SwiftUI sees the real AppKit pointer.
    public convenience init(
        interaction: XRPanelInteraction,
        movementScale: SIMD2<Float> = SIMD2(700, 500)
    ) {
        self.init(
            interaction: interaction,
            movementScale: movementScale,
            realSurfaceBegin: nil,
            realSurfaceEnd: nil,
            realPointerProvider: nil,
            realInputInvalidation: nil
        )
    }

    init(
        interaction: XRPanelInteraction,
        movementScale: SIMD2<Float>,
        realSurfaceBegin: (() -> Void)?,
        realSurfaceEnd: (() -> Void)?,
        realPointerProvider: (() -> SIMD2<Float>?)?,
        realInputInvalidation: (() -> Void)?
    ) {
        self.interaction = interaction
        self.movementScale = movementScale
        self.realSurfaceBegin = realSurfaceBegin
        self.realSurfaceEnd = realSurfaceEnd
        self.realPointerProvider = realPointerProvider
        self.realInputInvalidation = realInputInvalidation
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

        do {
            if realPointerProvider != nil {
                try acquireRealSurfaceCapture()
            } else {
                interaction.movePointer(to: SIMD2<Float>(0.5, 0.5))
                try acquireRelativeCapture()
            }
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

    /// Synchronize SwiftXR's software cursor with the real macOS cursor. This is
    /// a no-op for device-neutral relative capture. Applications using
    /// `XRMacPointerCapture(panel:)` should call it once per XR frame before
    /// drawing the panel.
    public func syncPointerPosition() {
        guard
            isCaptureRequested,
            let realPointerProvider,
            let position = realPointerProvider()
        else {
            return
        }

        if interaction.pointerPosition != position {
            interaction.setNativePointerPosition(position)
            realInputInvalidation?()
        }
    }

    @objc
    private func applicationDidResignActive() {
        releasePhysicalCapture(restoreCursor: true)
    }

    @objc
    private func applicationDidBecomeActive() {
        guard isCaptureRequested, !isCaptured else { return }

        if realPointerProvider != nil {
            try? acquireRealSurfaceCapture()
        } else {
            try? acquireRelativeCapture()
        }
    }

    // MARK: - Real SwiftUI mouse surface

    private func acquireRealSurfaceCapture() throws {
        guard isCaptureRequested, !isCaptured else { return }
        guard NSApplication.shared.isActive else {
            throw XRMacPointerCaptureError.applicationNotActive
        }

        // Crucially, do NOT call CGAssociateMouseAndMouseCursorPosition(false).
        // The real system cursor remains the pointer AppKit uses for hit testing,
        // hover and control tracking. We hide only its visual representation.
        realSurfaceBegin?()
        syncPointerPosition()

        NSCursor.hide()
        cursorHidden = true
        installRealSurfaceEventMonitor()
        isCaptured = true
    }

    private func installRealSurfaceEventMonitor() {
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

            let consumeEscape: Bool = MainActor.assumeIsolated {
                guard self.isCaptured else { return false }

                if event.type == .keyDown && event.keyCode == 53 {
                    self.escapeRequested = true
                    self.stop()
                    return true
                }

                // Do not alter or redispatch native pointer events. SwiftUI sees
                // the original NSEvent unchanged. We only mirror the real cursor
                // into the XR software cursor and schedule a texture refresh.
                self.syncPointerPosition()
                self.realInputInvalidation?()
                return false
            }

            return consumeEscape ? nil : event
        }
    }

    // MARK: - Device-neutral relative pointer capture

    private func acquireRelativeCapture() throws {
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
        installSemanticEventMonitor()
        isCaptured = true
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

    // MARK: - Release

    private func releasePhysicalCapture(restoreCursor: Bool) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        if realPointerProvider != nil {
            realSurfaceEnd?()
        } else if isCaptured || cursorHidden || !captureWindows.isEmpty {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        }

        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }

        if realPointerProvider == nil,
           restoreCursor,
           let savedCursorPosition {
            CGWarpMouseCursorPosition(savedCursorPosition)
        }

        destroyCaptureWindows()
        isCaptured = false
    }
}
