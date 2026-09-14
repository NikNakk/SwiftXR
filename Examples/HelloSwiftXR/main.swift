import Foundation
import Metal
import SwiftXR

func format(_ value: Float) -> String {
    String(format: "%.3f", value)
}

func formatPosition(_ pose: XRPose) -> String {
    let p = pose.position
    return "(\(format(p.x)), \(format(p.y)), \(format(p.z)))"
}

func formatOrientation(_ pose: XRPose) -> String {
    let q = pose.orientation
    return "(\(format(q.x)), \(format(q.y)), \(format(q.z)), \(format(q.w)))"
}

print("Hello from SwiftXR")

let capabilities = try XRRuntime.capabilities()

let metalSupport = capabilities.supportsMetal ? "yes" : "no"
print("Metal graphics support: \(metalSupport)")
try capabilities.requireMetal()

let instance = try XRInstance(applicationName: "HelloSwiftXR")
print("Runtime: \(instance.runtime.name) \(instance.runtime.version)")

let system = try instance.system()
print("System: \(system.info.name)")
print("Vendor ID: \(system.info.vendorID)")
print(
    "Max swapchain image: " +
    "\(system.info.maxSwapchainImageWidth)x\(system.info.maxSwapchainImageHeight)"
)
print("Max compositor layers: \(system.info.maxLayerCount)")

let orientationTracking = system.info.supportsOrientationTracking ? "yes" : "no"
let positionTracking = system.info.supportsPositionTracking ? "yes" : "no"
print("Orientation tracking: \(orientationTracking)")
print("Position tracking: \(positionTracking)")

let session = try system.makeSession()
print("Metal device: \(session.device.name)")
print("Metal command queue: created")
print("LOCAL reference space: created")
print("Initial session state: \(session.state)")

let startDeadline = Date().addingTimeInterval(10)
var lastPrintedState = session.state

while !session.isRunning && !session.shouldExit && Date() < startDeadline {
    for state in try session.pollEvents() where state != lastPrintedState {
        print("Session state: \(state)")
        lastPrintedState = state
    }

    if !session.isRunning && !session.shouldExit {
        Thread.sleep(forTimeInterval: 0.01)
    }
}

if session.isRunning {
    print("Session running: yes")
    print("Running 360 zero-layer frames; move the headset to exercise live view poses")

    var frameIndex = 0
    while frameIndex < 360 && session.isRunning && !session.shouldExit {
        for state in try session.pollEvents() where state != lastPrintedState {
            print("Session state: \(state)")
            lastPrintedState = state
        }

        guard session.isRunning && !session.shouldExit else {
            break
        }

        let frame = try session.nextFrame()

        if frameIndex % 30 == 0 {
            let periodMilliseconds = Double(frame.predictedDisplayPeriod) / 1_000_000.0
            print(
                "Frame \(frameIndex): views=\(frame.views.count) " +
                "shouldRender=\(frame.shouldRender) " +
                String(format: "period=%.3fms", periodMilliseconds)
            )

            if frame.views.count >= 2 {
                let left = frame.views[0]
                let right = frame.views[1]
                print("  left  position: \(formatPosition(left.pose))")
                print("  right position: \(formatPosition(right.pose))")
                print("  left orientation xyzw: \(formatOrientation(left.pose))")
            }

            let tracking = frame.trackingState
            print(
                "  tracking: orientation valid=\(tracking.orientationValid) " +
                "tracked=\(tracking.orientationTracked); " +
                "position valid=\(tracking.positionValid) " +
                "tracked=\(tracking.positionTracked)"
            )
        }

        frameIndex += 1
    }

    print("Completed \(frameIndex) OpenXR frames")

    if session.isRunning && !session.shouldExit {
        print("Requesting clean session exit")
        try session.requestExit()
    }

    let exitDeadline = Date().addingTimeInterval(5)
    while !session.shouldExit && Date() < exitDeadline {
        for state in try session.pollEvents() where state != lastPrintedState {
            print("Session state: \(state)")
            lastPrintedState = state
        }

        if !session.shouldExit {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    if session.shouldExit {
        print("Session exit acknowledged by runtime")
    } else {
        print("Session exit not yet acknowledged before diagnostic timeout")
    }
} else if session.shouldExit {
    print("Runtime requested exit before the session became running")
} else {
    print("Session did not reach READY within 10 seconds")
}
