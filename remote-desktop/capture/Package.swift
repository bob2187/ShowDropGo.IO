// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CaptureHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CaptureHelper",
            path: "Sources/CaptureHelper",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
