import SwiftXR

print("Hello from SwiftXR")

let capabilities = try XRRuntime.capabilities()

print("\nActive OpenXR runtime extensions:")
for extensionInfo in capabilities.extensions.sorted(by: { $0.name < $1.name }) {
    print("  \(extensionInfo.name) (v\(extensionInfo.version))")
}

let metalSupport = capabilities.supportsMetal ? "yes" : "no"
print("\nMetal graphics support: \(metalSupport)")
try capabilities.requireMetal()

print("\nSwiftXR is ready to create a Metal-backed OpenXR session once session support is implemented.")
