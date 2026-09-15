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
    private var nextMouseEventNumber = 1

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
        window.ignoresMouseEvents = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeFirstResponder(hostingView)

        // Keep a genuine AppKit responder/window hierarchy alive, but never put
        // the SwiftUI panel on the user's visible desktop. Mouse events are
        // queued explicitly with this window number by `handle(...)` below.
        window.orderFront(nil)

        self.window = window
        self.hostingView = hostingView
    }

    func renderImage() throws -> CGImage {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        // Let AppKit select the correct backing resolution. Explicitly creating
        // a pointSize*scale bitmap made cacheDisplay() fill only one quadrant on
        // Retina displays.
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

    /// Translate SwiftXR's device-neutral panel interaction into a coherent
    /// AppKit mouse stream addressed to this off-screen hosting window.
    ///
    /// Mouse events are posted through NSApplication rather than sent directly
    /// to NSWindow. This matters for native controls such as NSSlider/SwiftUI
    /// Slider: their nested AppKit tracking loop can dequeue the subsequent
    /// dragged/up events normally.
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
            postPointerMove(to: pointerPosition)

        case .pointerExited:
            break

        case let .pointerDown(button):
            guard let pointerPosition else { return }
            pressedButtons.insert(button)
            postPointerButton(button, down: true, at: pointerPosition)

        case let .pointerUp(button):
            guard let pointerPosition else { return }
            postPointerButton(button, down: false, at: pointerPosition)
            pressedButtons.remove(button)

        case let .scroll(delta):
            sendScroll(delta, pointerPosition: pointerPosition)
        }
    }

    private func prepareForInteraction() {
        if window.firstResponder !== hostingView {
            window.makeFirstResponder(hostingView)
        }
    }

    private func postPointerMove(to normalizedPosition: SIMD2<Float>) {
        prepareForInteraction()

        let type: NSEvent.EventType
        if pressedButtons.contains(.primary) {
            type = .leftMouseDragged
        } else if pressedButtons.contains(.secondary) {
            type = .rightMouseDragged
        } else {
            type = .mouseMoved
        }

        guard let event = makeMouseEvent(
            type: type,
            at: normalizedPosition,
            clickCount: pressedButtons.isEmpty ? 0 : 1,
            pressure: pressedButtons.isEmpty ? 0 : 1
        ) else {
            return
        }

        // Append rather than prepend. If several events are generated before
        // AppKit drains the queue, mouseDown -> dragged -> mouseUp ordering is
        // therefore preserved.
        NSApplication.shared.postEvent(event, atStart: false)
    }

    private func postPointerButton(
        _ button: XRPanelPointerButton,
        down: Bool,
        at normalizedPosition: SIMD2<Float>
    ) {
        prepareForInteraction()

        let type: NSEvent.EventType
        switch (button, down) {
        case (.primary, true): type = .leftMouseDown
        case (.primary, false): type = .leftMouseUp
        case (.secondary, true): type = .rightMouseDown
        case (.secondary, false): type = .rightMouseUp
        }

        guard let event = makeMouseEvent(
            type: type,
            at: normalizedPosition,
            clickCount: 1,
            pressure: down ? 1 : 0
        ) else {
            return
        }

        NSApplication.shared.postEvent(event, atStart: false)
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        at normalizedPosition: SIMD2<Float>,
        clickCount: Int,
        pressure: Float
    ) -> NSEvent? {
        let eventNumber = nextMouseEventNumber
        nextMouseEventNumber &+= 1

        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint(for: normalizedPosition),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        )
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

        // NSEvent has no public scroll-event factory that lets us assign a
        // windowNumber. Deliver scrolling directly to the known host window;
        // unlike mouse dragging it does not depend on a nested tracking loop.
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

        NSApplication.shared.postEvent(down, atStart: false)
        NSApplication.shared.postEvent(up, atStart: false)
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
