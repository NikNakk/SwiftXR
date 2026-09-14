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

let swapchain = try session.makeStereoSwapchain()
print(
    "Stereo swapchain: \(swapchain.width)x\(swapchain.height), " +
    "images=\(swapchain.imageCount), arraySize=2"
)
print("Swapchain Metal pixel format: \(swapchain.pixelFormat.rawValue)")
print(
    "Recommended views: " +
    "left \(swapchain.viewConfiguration.leftWidth)x\(swapchain.viewConfiguration.leftHeight), " +
    "right \(swapchain.viewConfiguration.rightWidth)x\(swapchain.viewConfiguration.rightHeight)"
)

let renderer = try WorldRenderer(device: session.device, swapchain: swapchain)
print("World renderer: cube + floor grid ready")
print("The grid is placed 1.5 m below the LOCAL-space origin")
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
    print("Rendering 900 world-locked stereo frames; move and lean around the cube")

    var frameIndex = 0
    while frameIndex < 900 && session.isRunning && !session.shouldExit {
        for state in try session.pollEvents() where state != lastPrintedState {
            print("Session state: \(state)")
            lastPrintedState = state
        }

        guard session.isRunning && !session.shouldExit else {
            break
        }

        let frame = try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
            try renderer.encode(
                frame: frame,
                texture: texture,
                commandBuffer: commandBuffer
            )
        }

        if frameIndex % 120 == 0 {
            let periodMilliseconds = Double(frame.predictedDisplayPeriod) / 1_000_000.0
            print(
                "Frame \(frameIndex): views=\(frame.views.count) " +
                "shouldRender=\(frame.shouldRender) " +
                String(format: "period=%.3fms", periodMilliseconds)
            )

            if frame.views.count >= 2 {
                print("  left  position: \(formatPosition(frame.views[0].pose))")
                print("  right position: \(formatPosition(frame.views[1].pose))")
            }
        }

        frameIndex += 1
    }

    print("Completed \(frameIndex) world-rendered OpenXR frames")

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
