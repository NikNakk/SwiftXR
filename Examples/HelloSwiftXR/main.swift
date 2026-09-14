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
print("Orientation tracking: \(system.info.supportsOrientationTracking ? "yes" : "no")")
print("Position tracking: \(system.info.supportsPositionTracking ? "yes" : "no")")

let device: any MTLDevice = try system.metalDevice()
print("Metal device: \(device.name)")

print("Ready to create a Metal-backed OpenXR session.")
