// swift-tools-version: 6.0
// spotcoreFFI.xcframework and Sources/SpotCoreKit/spotcore.swift are build
// outputs of scripts/build-xcframework.sh; run it before resolving this package.
import PackageDescription

let package = Package(
    name: "SpotCoreKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpotCoreKit", targets: ["SpotCoreKit"]),
    ],
    targets: [
        .binaryTarget(name: "spotcoreFFI", path: "spotcoreFFI.xcframework"),
        .target(
            name: "SpotCoreKit",
            dependencies: ["spotcoreFFI"],
            // librespot pulls in these system frameworks transitively.
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(name: "SpotCoreKitTests", dependencies: ["SpotCoreKit"]),
    ]
)
