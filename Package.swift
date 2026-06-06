// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BokslTab",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BokslTab", targets: ["BokslTabApp"]),
        .library(name: "BokslTabCore", targets: ["BokslTabCore"]),
        .library(name: "BokslTabMacOSAdapters", targets: ["BokslTabMacOSAdapters"]),
        .library(name: "BokslTabUI", targets: ["BokslTabUI"])
    ],
    targets: [
        .target(name: "BokslTabCore"),
        .target(
            name: "BokslTabMacOSAdapters",
            dependencies: ["BokslTabCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .target(
            name: "BokslTabUI",
            dependencies: ["BokslTabCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "BokslTabApp",
            dependencies: [
                "BokslTabCore",
                "BokslTabMacOSAdapters",
                "BokslTabUI"
            ]
        ),
        .testTarget(
            name: "BokslTabCoreTests",
            dependencies: ["BokslTabCore"]
        ),
        .testTarget(
            name: "BokslTabMacOSAdaptersTests",
            dependencies: [
                "BokslTabCore",
                "BokslTabMacOSAdapters"
            ]
        ),
        .testTarget(
            name: "BokslTabUITests",
            dependencies: [
                "BokslTabCore",
                "BokslTabUI"
            ]
        )
    ]
)
