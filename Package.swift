// swift-tools-version: 6.0

import PackageDescription

let openXRExecutableLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"],
        .when(platforms: [.macOS])
    )
]

let package = Package(
    name: "SwiftXR",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftXR", targets: ["SwiftXR"]),
        .executable(name: "swiftxr-probe", targets: ["SwiftXRProbe"]),
        .executable(name: "hello-swiftxr", targets: ["HelloSwiftXR"]),
    ],
    targets: [
        .systemLibrary(
            name: "COpenXR",
            path: "Sources/COpenXR"
        ),
        .target(
            name: "SwiftXR",
            dependencies: ["COpenXR"]
        ),
        .executableTarget(
            name: "SwiftXRProbe",
            dependencies: ["SwiftXR"],
            linkerSettings: openXRExecutableLinkerSettings
        ),
        .executableTarget(
            name: "HelloSwiftXR",
            dependencies: ["SwiftXR"],
            path: "Examples/HelloSwiftXR",
            linkerSettings: openXRExecutableLinkerSettings
        ),
    ]
)
