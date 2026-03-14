// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenClawKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v26),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "OpenClawProtocol", targets: ["OpenClawProtocol"]),
        .library(name: "OpenClawCore", targets: ["OpenClawCore"]),
        .library(name: "OpenClawGateway", targets: ["OpenClawGateway"]),
        .library(name: "OpenClawAgents", targets: ["OpenClawAgents"]),
        .library(name: "OpenClawPlugins", targets: ["OpenClawPlugins"]),
        .library(name: "OpenClawChannels", targets: ["OpenClawChannels"]),
        .library(name: "OpenClawMemory", targets: ["OpenClawMemory"]),
        .library(name: "OpenClawMedia", targets: ["OpenClawMedia"]),
        .library(name: "OpenClawModels", targets: ["OpenClawModels"]),
        .library(name: "OpenClawSkills", targets: ["OpenClawSkills"]),
        .library(name: "OpenClawKit", targets: ["OpenClawKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            revision: "a654a899a0e2802bf66429214e8ebc51c397c4d9"
        ),
    ],
    targets: [
        .target(
            name: "OpenClawProtocol",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawCore",
            dependencies: [
                "OpenClawProtocol",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawGateway",
            dependencies: ["OpenClawProtocol", "OpenClawCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawModels",
            dependencies: ["OpenClawCore", "OpenClawProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawSkills",
            dependencies: [
                "OpenClawCore",
                .product(name: "WasmKit", package: "WasmKit", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "WasmKitWASI", package: "WasmKit", condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.macOS, .iOS])),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawAgents",
            dependencies: [
                "OpenClawCore",
                "OpenClawGateway",
                "OpenClawProtocol",
                "OpenClawModels",
                "OpenClawSkills",
                "OpenClawMedia",
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawPlugins",
            dependencies: ["OpenClawCore", "OpenClawProtocol", "OpenClawGateway", "OpenClawAgents"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawChannels",
            dependencies: [
                "OpenClawCore",
                "OpenClawProtocol",
                "OpenClawGateway",
                "OpenClawPlugins",
                "OpenClawAgents",
                "OpenClawMemory",
                "OpenClawSkills",
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawMemory",
            dependencies: ["OpenClawCore", "OpenClawProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawMedia",
            dependencies: ["OpenClawCore", "OpenClawProtocol"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OpenClawKit",
            dependencies: [
                "OpenClawProtocol",
                "OpenClawCore",
                "OpenClawGateway",
                "OpenClawAgents",
                "OpenClawPlugins",
                "OpenClawChannels",
                "OpenClawMemory",
                "OpenClawMedia",
                "OpenClawModels",
                "OpenClawSkills",
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "OpenClawKitTests",
            dependencies: ["OpenClawKit", "OpenClawGateway", "OpenClawCore", "OpenClawProtocol", "OpenClawModels"],
            swiftSettings: [
                .enableExperimentalFeature("SwiftTesting"),
            ]
        ),
        .testTarget(
            name: "OpenClawKitE2ETests",
            dependencies: ["OpenClawKit", "OpenClawGateway", "OpenClawCore", "OpenClawProtocol", "OpenClawModels"],
            swiftSettings: [
                .enableExperimentalFeature("SwiftTesting"),
            ]
        ),
    ]
)
