// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DJIMicAutoSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DJIMicAutoSwitch", targets: ["DJIMicAutoSwitch"])
    ],
    targets: [
        .executableTarget(
            name: "DJIMicAutoSwitch",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "DJIMicAutoSwitchTests",
            dependencies: ["DJIMicAutoSwitch"]
        )
    ],
    swiftLanguageModes: [.v5]
)
