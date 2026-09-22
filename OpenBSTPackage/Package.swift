import PackageDescription

let package = Package(
    name: "OpenBST",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "OpenBST", targets: ["OpenBSTWrapper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Mudb0y/openbst", from: "0.0.0") // Dummy, we'll use local
    ],
    targets: [
        .binaryTarget(
            name: "OpenBSTBinary",
            path: "../OpenBST.xcframework"
        ),
        .target(
            name: "OpenBSTWrapper",
            dependencies: ["OpenBSTBinary"],
            path: "Sources/OpenBST"
        ),
    ]
)
