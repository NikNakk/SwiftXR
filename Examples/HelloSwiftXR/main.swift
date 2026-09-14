import Foundation
import Metal
import SwiftXR

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
    print("Requesting clean session exit")
    try session.requestExit()

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
