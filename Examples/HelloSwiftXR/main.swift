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

func encodeTestField(
    texture: any MTLTexture,
    commandBuffer: any MTLCommandBuffer,
    frameIndex: Int
) {
    let pulse = 0.5 + 0.5 * sin(Double(frameIndex) * 0.04)
    let clearColor = MTLClearColor(
        red: 0.04 + 0.05 * pulse,
        green: 0.12 + 0.28 * pulse,
        blue: 0.22 + 0.45 * pulse,
        alpha: 1.0
    )

    for eye in 0..<2 {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].slice = eye
        descriptor.colorAttachments[0].level = 0
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }
    }
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
    print("Rendering 360 stereo projection frames; the headset should show a pulsing blue field")

    var frameIndex = 0
    while frameIndex < 360 && session.isRunning && !session.shouldExit {
        for state in try session.pollEvents() where state != lastPrintedState {
            print("Session state: \(state)")
            lastPrintedState = state
        }

        guard session.isRunning && !session.shouldExit else {
            break
        }

        let currentFrame = frameIndex
        let frame = try session.renderFrame(to: swapchain) { _, texture, commandBuffer in
            encodeTestField(
                texture: texture,
                commandBuffer: commandBuffer,
                frameIndex: currentFrame
            )
        }

        if frameIndex % 30 == 0 {
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

    print("Completed \(frameIndex) rendered OpenXR frames")

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
