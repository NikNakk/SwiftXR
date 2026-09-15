import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class XRSwiftUIHost<Content: View> {
    let pointSize: CGSize
    let scale: CGFloat

    private let window: NSWindow
    private let hostingView: NSHostingView<Content>
    private var pressedButtons: Set<XRPanelPointerButton> = []

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

        let window = NSWindow(
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

        // AppKit explicitly recommends obtaining the bitmap representation from
        // the view when using cacheDisplay(in:to:). This preserves the view's
        // native backing format and coordinate conventions instead of guessing
        // them in a manually-created bitmap.
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
            break

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

    private func sendPointerMove(to normalizedPosition: SIMD2<Float>) {
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
            clickCount: 0,
            pressure: pressedButtons.isEmpty ? 0 : 1
        ) else {
            return
        }

        // NSHostingView overrides these AppKit mouse methods specifically to
        // bridge events into its SwiftUI hierarchy. Deliver directly to that
        // bridge rather than asking a separate hidden window to redispatch them.
        switch type {
        case .leftMouseDragged:
            hostingView.mouseDragged(with: event)
        case .rightMouseDragged:
            hostingView.rightMouseDragged(with: event)
        default:
            hostingView.mouseMoved(with: event)
        }
    }

    private func sendPointerButton(
        _ button: XRPanelPointerButton,
        down: Bool,
        at normalizedPosition: SIMD2<Float>
    ) {
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

        switch type {
        case .leftMouseDown:
            hostingView.mouseDown(with: event)
        case .leftMouseUp:
            hostingView.mouseUp(with: event)
        case .rightMouseDown:
            hostingView.rightMouseDown(with: event)
        case .rightMouseUp:
            hostingView.rightMouseUp(with: event)
        default:
            break
        }
    }

    private func sendScroll(
        _ delta: SIMD2<Float>,
        pointerPosition: SIMD2<Float>?
    ) {
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

        hostingView.scrollWheel(with: event)
    }

    private func sendKey(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) {
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

        window.makeFirstResponder(hostingView)
        hostingView.keyDown(with: down)
        hostingView.keyUp(with: up)
    }

    private func windowPoint(for normalizedPosition: SIMD2<Float>) -> NSPoint {
        // Panel coordinates are always top-left based. Convert through the
        // hosting view so this remains correct regardless of whether Apple's
        // current NSHostingView implementation reports a flipped coordinate
        // system.
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
