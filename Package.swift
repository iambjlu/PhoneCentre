// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhoneCentre",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhoneCentre",
            path: "Sources/PhoneCentre",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
