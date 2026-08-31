// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "nicegram-package",
    dependencies: [
        .package(path: "packages/nicegram-assistant-ios"),
    ]
)
