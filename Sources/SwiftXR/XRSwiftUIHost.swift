import AppKit
import CoreGraphics
import SwiftUI

private final class XRSwiftUIHostingWindow: NSWindow {
    // This window is never presented on a desktop display. Its backing density
    // is the XR panel's requested density, not that of the Mac's Retina screen.
    var panelBackingScale: CGFloat = 1
    override var backingScaleFactor: CGFloat { panelBackingScale }
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
    private var captureBitmap: NSBitmapImageRep?

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
        window.panelBackingScale = scale
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
        // the SwiftUI panel on the user's visible desktop. Button and drag events
        // are queued explicitly with this window number by `handle(...)` below.
        window.orderFront(nil)

        self.window = window
        self.hostingView = hostingView
    }

    func renderImage() throws -> CGImage {
        hostingView.layoutSubtreeIfNeeded()
        configureScrollGutters(in: hostingView)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        // Use the off-screen window's requested backing scale and retain the
        // bitmap between updates instead of allocating a full panel each time.
        if captureBitmap == nil {
            captureBitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        }
        guard let bitmap = captureBitmap else {
            throw XRSwiftUIPanelError.bitmapContextCreationFailed
        }

        bitmap.size = pointSize
        // cacheDisplay composites into the supplied bitmap. Reuse must start
        // transparent, or semi-opaque panels become opaque over successive
        // refreshes and pixels from the previous mode survive in empty areas.
        bitmap.bitmapData?.update(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let image = bitmap.cgImage else {
            throw XRSwiftUIPanelError.imageRenderingFailed
        }
        return image
    }

    /// Translate SwiftXR's device-neutral panel interaction into a coherent
    /// AppKit mouse stream addressed to this off-screen hosting window.
    ///
    /// Button and drag events are posted through NSApplication rather than sent
    /// directly to NSWindow. This matters for native controls such as
    /// NSSlider/SwiftUI Slider: their nested AppKit tracking loop can dequeue the
    /// subsequent dragged/up events normally. Ordinary hover movement is sent
    /// synchronously so it cannot build a queue ahead of a later click.
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
            deliverPointerMove(to: pointerPosition)

        case .pointerExited:
            // Move outside the host before releasing a lost ray/drag. Releasing
            // at the previous hit can accidentally activate a button.
            deliverPointerMove(to: SIMD2<Float>(-1, -1))

        case let .pointerDown(button):
            guard let pointerPosition else { return }
            pressedButtons.insert(button)
            postPointerButton(button, down: true, at: pointerPosition)

        case let .pointerUp(button):
            guard pressedButtons.contains(button) else { return }
            postPointerButton(button, down: false,
                              at: pointerPosition ?? SIMD2<Float>(-1, -1))
            pressedButtons.remove(button)

        case let .scroll(delta):
            sendScroll(delta, pointerPosition: pointerPosition)
        }
    }

    private func prepareForInteraction() {
        // The synthetic mouse stream is addressed to this hidden window. Keep it
        // genuinely key so AppKit/SwiftUI sees active controls immediately,
        // rather than relying on a later Cmd-Tab activation cycle to establish
        // the responder hierarchy. Physical capture overlays are deliberately
        // non-key windows, so they do not displace it.
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== hostingView {
            window.makeFirstResponder(hostingView)
        }
    }

    private func deliverPointerMove(to normalizedPosition: SIMD2<Float>) {
        // A hovering XR ray must not steal key-window status from the desktop
        // companion or its menus. Activation/dragging still establishes the
        // native host's responder chain when it is actually needed.
        if !pressedButtons.isEmpty { prepareForInteraction() }

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

        if type == .mouseMoved {
            // Hover does not need to participate in an AppKit nested tracking
            // loop. Sending it immediately prevents a high-rate XR pointer from
            // filling the application event queue and delaying a subsequent
            // mouseDown/mouseUp pair.
            window.sendEvent(event)
        } else {
            // Dragged events must remain queued so a native Slider's nested
            // tracking loop can dequeue them normally.
            NSApplication.shared.postEvent(event, atStart: false)
        }
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

        let windowLocation = windowPoint(for: pointerPosition ?? SIMD2(0.5, 0.5))
        let local = hostingView.convert(windowLocation, from: nil)
        let hit = hostingView.hitTest(local)
        let scrollView = (hit as? NSScrollView) ?? hit?.enclosingScrollView
            ?? verticalScrollView(in: hostingView)
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        // Preserve fractional points; rounding at XR refresh rate introduces
        // dead zones and uneven steps. Scroll only when this view can scroll.
        if document.bounds.height > bounds.height {
            bounds.origin.y += CGFloat(delta.y * 40) * (document.isFlipped ? -1 : 1)
        }
        if document.bounds.width > bounds.width {
            bounds.origin.x -= CGFloat(delta.x * 40)
        }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func configureScrollGutters(in view: NSView) {
        if let scroll = view as? NSScrollView, scroll.scrollerStyle != .legacy {
            // Give the scrollbar a real layout gutter. An overlay scroller
            // shares pixels with content and cannot be held fixed by excluding
            // an arbitrary strip of the captured image.
            scroll.scrollerStyle = .legacy
            scroll.tile()
        }
        for subview in view.subviews { configureScrollGutters(in: subview) }
    }

    func scrollInfo() -> XRPanelScrollInfo? {
        guard let scroll = verticalScrollView(in: hostingView), let document = scroll.documentView else { return nil }
        let clip = scroll.contentView
        guard clip.bounds.height > 0 else { return nil }
        let viewport = clip.convert(clip.bounds, to: hostingView)
        let width = hostingView.bounds.width
        let height = hostingView.bounds.height
        let top = hostingView.isFlipped ? viewport.minY : height - viewport.maxY
        let offset = document.isFlipped
            ? clip.bounds.minY - document.bounds.minY
            : document.bounds.maxY - clip.bounds.maxY
        return XRPanelScrollInfo(viewport: SIMD4(Float(viewport.minX / width), Float(top / height),
                                                Float(viewport.width / width), Float(viewport.height / height)),
                                 offset: Float(offset / clip.bounds.height))
    }

    private func verticalScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height { return scroll }
        for subview in view.subviews where !subview.isHidden {
            if let found = verticalScrollView(in: subview) { return found }
        }
        return nil
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
