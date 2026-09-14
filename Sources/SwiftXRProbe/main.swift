import Darwin
import SwiftXR

do {
    let capabilities = try XRRuntime.capabilities()

    print("OpenXR runtime detected")
    print("Extensions: \(capabilities.extensions.count)")
    print("XR_KHR_metal_enable: \(capabilities.supportsMetal ? \"yes\" : \"no\")")

    try capabilities.requireMetal()
    print("SwiftXR prerequisite check passed")
} catch {
    fputs("swiftxr-probe: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
