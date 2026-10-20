// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "crossui-spike",
    dependencies: [
        .package(url: "https://github.com/moreSwift/swift-cross-ui", exact: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "crossui-spike",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ]
        ),
    ]
)
