// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ShippingShared",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(name: "ShippingShared", targets: ["ShippingShared"]),
    ],
    targets: [
        .target(
            name: "ShippingShared",
            path: ".",
            exclude: ["Package.swift", "Tests"],
            sources: ["ShippingInbox.swift"]
        ),
        .testTarget(
            name: "ShippingSharedTests",
            dependencies: ["ShippingShared"],
            path: "Tests"
        ),
    ]
)
