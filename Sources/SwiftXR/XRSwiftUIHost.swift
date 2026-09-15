import AppKit
import CoreGraphics
import SwiftUI

private final class XRSwiftUIHostingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class XRSwiftUIHost<Content: View> {
    let pointSize: CGSize
    let scale: CGFloat

    private let window: XRSwiftUIHostingWindow
    private let containerView: NSView
    private let hostingView: NSHostingView<Content>

    // Device-neutral semantic-pointer state. The real macOS mouse path bypasses
    // this and lets AppKit deliver genuine events to NSHostingView.
    private var pressedButtons: Set<XRPanelPointerButton> = []
    private var pendingAccessibilityButton = false
    private var isRealMouseSurfaceActive = false

    init(
        pointSize: CGSize,
        scale: CGFloat,
        content: Content
    ) {
        _ = NSApplication.shared

        self.pointSize = pointSize
        self.scale = scale

        let frame = NSRect(origin: .zero, size: pointSize)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = frame
        hostingView.bounds = frame
        hostingView.autoresizingMask = []
        hostingView.wantsLayer = true

        let containerView = NSView(frame: frame)
        containerView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        let window = XRSwiftUIHostingWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.contentView = containerView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeFirstResponder(hostingView)
        window.orderFront(nil)

        self.window = window
        self.containerView = containerView
        self.hostingView = hostingView
    }

    func renderImage() throws -> CGImage {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        // Use AppKit's own caching representation. This is the path that gave us
        // correct full-panel rendering before the real-mouse experiment. An
        // explicitly allocated pointSize*scale bitmap caused cacheDisplay() to
        // fill only one quadrant on Retina/2x panels.
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XRSwiftUIPanelError.bitmapContextCreationFailed
        }

        bitmap.size = pointSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let image = bitmap.cgImage else {
            throw XRSwiftUIPanelError.imageRenderingFailed
        }
        return image
    }

    // MARK: - Real macOS mouse surface

    /// Put the real hosted SwiftUI hierarchy inside an effectively invisible
    /// desktop-sized interaction window without scaling the hosting view itself.
    /// AppKit therefore delivers genuine mouse/trackpad events using the same
    /// coordinates SwiftUI uses for layout and rasterization.
    func beginRealMouseCaptureSurface() {
        guard !isRealMouseSurfaceActive else {
            prepareForInteraction()
            return
        }

        let screens = NSScreen.screens
        guard let first = screens.first else {
            prepareForInteraction()
            return
        }

        let desktopFrame = screens.dropFirst().reduce(first.frame) { partial, screen in
            partial.union(screen.frame)
        }

        isRealMouseSurfaceActive = true
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        window.level = .screenSaver

        // Keep a non-zero alpha so AppKit treats the window as a live interactive
        // surface. cacheDisplay() rasterizes the hosting view independently.
        window.alphaValue = 0.001
        window.setFrame(desktopFrame, display: false)

        // Crucially, do not stretch NSHostingView to the desktop and then alter
        // its bounds. SwiftUI does not behave like a simple affine canvas under
        // that transformation. Keep it exactly panel-sized and put it around the
        // current real cursor instead.
        let mouseInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let bounds = containerView.bounds
        let maxX = max(bounds.minX, bounds.maxX - pointSize.width)
        let maxY = max(bounds.minY, bounds.maxY - pointSize.height)
        let origin = NSPoint(
            x: min(max(mouseInWindow.x - pointSize.width / 2, bounds.minX), maxX),
            y: min(max(mouseInWindow.y - pointSize.height / 2, bounds.minY), maxY)
        )
        hostingView.frame = NSRect(origin: origin, size: pointSize)
        hostingView.bounds = NSRect(origin: .zero, size: pointSize)

        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(hostingView)
    }

    func endRealMouseCaptureSurface() {
        guard isRealMouseSurfaceActive else { return }
        isRealMouseSurfaceActive = false

        hostingView.frame = NSRect(origin: .zero, size: pointSize)
        hostingView.bounds = NSRect(origin: .zero, size: pointSize)

        window.alphaValue = 1
        window.level = .normal
        window.collectionBehavior = []
        window.setFrame(
            NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: pointSize),
            display: false
        )
        window.orderFront(nil)
    }

    /// Current real macOS cursor position expressed in SwiftXR's normalized
    /// top-left panel coordinates. If the pointer leaves the native-size child
    /// view, move the associated system cursor back to its nearest edge. We do
    /// not manufacture or retarget NSEvents: events within the panel are the
    /// ordinary AppKit events generated by the physical mouse/trackpad.
    func realMousePointerPosition() -> SIMD2<Float>? {
        guard isRealMouseSurfaceActive else { return nil }

        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let panelFrame = hostingView.frame
        let inset: CGFloat = 0.5
        let clamped = NSPoint(
            x: min(max(pointInWindow.x, panelFrame.minX + inset), panelFrame.maxX - inset),
            y: min(max(pointInWindow.y, panelFrame.minY + inset), panelFrame.maxY - inset)
        )

        if abs(clamped.x - pointInWindow.x) > 0.001 ||
            abs(clamped.y - pointInWindow.y) > 0.001,
           let cgLocation = CGEvent(source: nil)?.location {
            let dx = clamped.x - pointInWindow.x
            let dy = clamped.y - pointInWindow.y
            CGWarpMouseCursorPosition(
                CGPoint(x: cgLocation.x + dx, y: cgLocation.y - dy)
            )
        }

        let pointInHost = hostingView.convert(clamped, from: nil)
        let width = max(hostingView.bounds.width, 1)
        let height = max(hostingView.bounds.height, 1)

        let x = Float(pointInHost.x / width)
        let y: Float
        if hostingView.isFlipped {
            y = Float(pointInHost.y / height)
        } else {
            y = Float(1 - pointInHost.y / height)
        }

        return SIMD2(
            min(max(x, 0), 1),
            min(max(y, 0), 1)
        )
    }

    // MARK: - Device-neutral semantic path

    func handle(
        _ event: XRPanelInteractionEvent,
        pointerPosition: SIMD2<Float>?
    ) {
        switch event {
        case .navigate(.up):
            sendKey(keyCode: 126, characters: Self.functionKey(0xF700))
        case .navigate(.down):
            sendKey(keyCode: 125, characters: Self.functionKey(0xF701))
        case .navigate(.left):
            sendKey(keyCode: 123, characters: Self.functionKey(0xF702))
        case .navigate(.right):
            sendKey(keyCode: 124, characters: Self.functionKey(0xF703))
        case .navigate(.next):
            sendKey(keyCode: 48, characters: "\t")
        case .navigate(.previous):
            sendKey(keyCode: 48, characters: "\t", modifiers: [.shift])

        case .select:
            sendKey(keyCode: 49, characters: " ")

        case .back:
            sendKey(keyCode: 53, characters: "\u{1b}")

        case .pointerMoved, .pointerMovedBy:
            guard let pointerPosition else { return }
            sendPointerMove(to: pointerPosition)

        case .pointerExited:
            pendingAccessibilityButton = false

        case let .pointerDown(button):
            guard let pointerPosition else { return }
            pressedButtons.insert(button)
            sendPointerButton(button, down: true, at: pointerPosition)

        case let .pointerUp(button):
            guard let pointerPosition else { return }
            sendPointerButton(button, down: false, at: pointerPosition)
            pressedButtons.remove(button)

        case let .scroll(delta):
            sendScroll(delta, pointerPosition: pointerPosition)
        }
    }

    private func prepareForInteraction() {
        if !window.isKeyWindow {
            window.makeKey()
        }
        if window.firstResponder !== hostingView {
            window.makeFirstResponder(hostingView)
        }
    }

    private func sendPointerMove(to normalizedPosition: SIMD2<Float>) {
        prepareForInteraction()

        if pendingAccessibilityButton && pressedButtons.contains(.primary) {
            return
        }

        let point = windowPoint(for: normalizedPosition)
        let type: NSEvent.EventType

        if pressedButtons.contains(.primary) {
            type = .leftMouseDragged
        } else if pressedButtons.contains(.secondary) {
            type = .rightMouseDragged
        } else {
            type = .mouseMoved
        }

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: pressedButtons.isEmpty ? 0 : 1,
            pressure: pressedButtons.isEmpty ? 0 : 1
        ) else {
            return
        }

        window.sendEvent(event)
    }

    private func sendPointerButton(
        _ button: XRPanelPointerButton,
        down: Bool,
        at normalizedPosition: SIMD2<Float>
    ) {
        prepareForInteraction()

        if button == .primary {
            if down {
                if accessibilityButton(at: normalizedPosition) != nil {
                    pendingAccessibilityButton = true
                    return
                }
            } else if pendingAccessibilityButton {
                pendingAccessibilityButton = false
                if let releaseButton = accessibilityButton(at: normalizedPosition) {
                    _ = releaseButton.accessibilityPerformPress()
                }
                return
            }
        }

        let point = windowPoint(for: normalizedPosition)
        let type: NSEvent.EventType

        switch (button, down) {
        case (.primary, true): type = .leftMouseDown
        case (.primary, false): type = .leftMouseUp
        case (.secondary, true): type = .rightMouseDown
        case (.secondary, false): type = .rightMouseUp
        }

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: down ? 1 : 0
        ) else {
            return
        }

        window.sendEvent(event)
    }

    private func accessibilityButton(
        at normalizedPosition: SIMD2<Float>
    ) -> (any NSAccessibilityProtocol)? {
        let pointInWindow = windowPoint(for: normalizedPosition)
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)

        guard
            let hit = hostingView.accessibilityHitTest(pointOnScreen),
            let accessible = hit as? any NSAccessibilityProtocol,
            accessible.accessibilityRole() == .button
        else {
            return nil
        }

        return accessible
    }

    private func sendScroll(
        _ delta: SIMD2<Float>,
        pointerPosition: SIMD2<Float>?
    ) {
        prepareForInteraction()

        let x = Int32((delta.x * 40).rounded())
        let y = Int32((delta.y * 40).rounded())

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: y,
            wheel2: x,
            wheel3: 0
        ) else {
            return
        }

        if let pointerPosition {
            let pointInWindow = windowPoint(for: pointerPosition)
            cgEvent.location = window.convertPoint(toScreen: pointInWindow)
        }

        guard let event = NSEvent(cgEvent: cgEvent) else {
            return
        }

        window.sendEvent(event)
    }

    private func sendKey(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        prepareForInteraction()

        let timestamp = ProcessInfo.processInfo.systemUptime

        guard
            let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        else {
            return
        }

        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func windowPoint(for normalizedPosition: SIMD2<Float>) -> NSPoint {
        let x = CGFloat(normalizedPosition.x) * hostingView.bounds.width
        let y: CGFloat
        if hostingView.isFlipped {
            y = CGFloat(normalizedPosition.y) * hostingView.bounds.height
        } else {
            y = (1 - CGFloat(normalizedPosition.y)) * hostingView.bounds.height
        }

        return hostingView.convert(NSPoint(x: x, y: y), to: nil)
    }

    private static func functionKey(_ value: UInt32) -> String {
        guard let scalar = UnicodeScalar(value) else { return "" }
        return String(scalar)
    }
}
