import ApplicationServices
import CoreGraphics
import simd

/// Stage-2 input bridge for a future Sense-controller ray or other XR pointer.
///
/// DesktopSurfaceGeometry produces top-left-origin UVs. Quartz display services
/// also use a top-left-origin global display coordinate space, so a hit can map
/// directly onto the captured physical display without passing through AppKit's
/// bottom-left coordinate convention.
struct DesktopPointerController {
    let displayID: CGDirectDisplayID

    var displayBounds: CGRect {
        CGDisplayBounds(displayID)
    }

    func quartzPoint(forUV uv: SIMD2<Float>) -> CGPoint {
        let clampedX = CGFloat(min(max(uv.x, 0), 1))
        let clampedY = CGFloat(min(max(uv.y, 0), 1))
        let bounds = displayBounds

        return CGPoint(
            x: bounds.minX + clampedX * bounds.width,
            y: bounds.minY + clampedY * bounds.height
        )
    }

    /// Move the real macOS pointer to a virtual-desktop hit. Cursor warping does
    /// not itself synthesize a mouse event.
    @discardableResult
    func movePointer(toUV uv: SIMD2<Float>) -> CGError {
        CGWarpMouseCursorPosition(quartzPoint(forUV: uv))
    }

    /// System-wide click injection is deliberately separate from pointer motion.
    /// macOS may require Accessibility permission for posted input events.
    func primaryClick(atUV uv: SIMD2<Float>) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let point = quartzPoint(forUV: uv)

        guard
            let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            return false
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func scroll(verticalLines: Int32) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: verticalLines,
            wheel2: 0,
            wheel3: 0
        ) else {
            return false
        }

        event.post(tap: .cghidEventTap)
        return true
    }
}
