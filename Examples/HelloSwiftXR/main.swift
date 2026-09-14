import SwiftXR

print("Hello from SwiftXR")

let capabilities = try XRRuntime.capabilities()

print("\nActive OpenXR runtime extensions:")
for extensionInfo in capabilities.extensions.sorted(by: { $0.name < $1.name }) {
    print("  \(extensionInfo.name) (v\(extensionInfo.version))")
}

print("\nMetal graphics support: \(capabilities.supportsMetal ? \"yes\" : \"no\")")
try capabilities.requireMetal()

print("\nSwiftXR is ready to create a Metal-backed OpenXR session once session support is implemented.")
