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
    private let hostingView: NSHostingView<Content>
    private var pressedButtons: Set<XRPanelPointerButton> = []
    private var pendingAccessibilityButton: (any NSAccessibilityProtocol)?

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
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true

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
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeFirstResponder(hostingView)

        // Keep the surface backed by a real NSWindow/responder chain without
        // placing anything visible on the user's desktop.
        window.orderBack(nil)

        self.window = window
        self.hostingView = hostingView
    }

    func renderImage() throws -> CGImage {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

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
            pendingAccessibilityButton = nil

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

        // A SwiftUI Button is activated through the accessibility fallback below.
        // While it is held, do not feed an unmatched drag stream into the hosting
        // view: merely update XRPanelInteraction's virtual pointer position.
        if pendingAccessibilityButton != nil && pressedButtons.contains(.primary) {
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

        // This direct host-window path is known to preserve normal Toggle and
        // Slider interaction in the off-screen SwiftUI hierarchy.
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
                // Standard SwiftUI Button actions have not reliably completed via
                // synthetic AppKit mouse-up events, although Toggle and Slider do.
                // Use SwiftUI's accessibility element for the semantic Button
                // press only when hit-testing identifies an actual button.
                if let accessibilityButton = accessibilityButton(
                    at: normalizedPosition
                ) {
                    pendingAccessibilityButton = accessibilityButton
                    return
                }
            } else if let pendingAccessibilityButton {
                defer { self.pendingAccessibilityButton = nil }

                // Match normal button semantics: activate only if release is still
                // over the same accessible button that was pressed.
                if let releaseButton = accessibilityButton(
                    at: normalizedPosition
                ),
                   (releaseButton as AnyObject) ===
                        (pendingAccessibilityButton as AnyObject) {
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
