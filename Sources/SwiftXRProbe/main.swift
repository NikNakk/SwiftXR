import Darwin
import SwiftXR

do {
    let capabilities = try XRRuntime.capabilities()

    print("OpenXR runtime detected")
    print("Extensions: \(capabilities.extensions.count)")
    let metalSupport = capabilities.supportsMetal ? "yes" : "no"
    print("XR_KHR_metal_enable: \(metalSupport)")

    try capabilities.requireMetal()
    print("SwiftXR prerequisite check passed")
} catch {
    fputs("swiftxr-probe: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
