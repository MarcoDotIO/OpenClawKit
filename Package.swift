// swift-tools-version: 6.2

import PackageDescription

var products: [Product] = [
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
    .library(name: "OpenClawMCP", targets: ["OpenClawMCP"]),
]

var targets: [Target] = [
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
        dependencies: [
            "OpenClawCore",
            "OpenClawProtocol",
            .product(
                name: "OpenAIKit",
                package: "OpenAIKit",
                condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])
            ),
        ],
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
    // Model Context Protocol client runtime. Cross-platform (Linux included);
    // stdio transport is limited to macOS/Linux at the source level.
    .target(
        name: "OpenClawMCP",
        dependencies: ["OpenClawCore", "OpenClawProtocol", "OpenClawAgents"],
        swiftSettings: [
            .enableUpcomingFeature("StrictConcurrency"),
        ]
    ),
]

#if !os(Linux)
products += [
    .library(name: "OpenClawKit", targets: ["OpenClawKit"]),
    .library(name: "OpenClawChatUI", targets: ["OpenClawChatUI"]),
    .library(name: "OpenClawNativeState", targets: ["OpenClawNativeState"]),
    .library(name: "OpenClawAppIntents", targets: ["OpenClawAppIntents"]),
    .library(name: "OpenClawChatStore", targets: ["OpenClawChatStore"]),
]

targets += [
    // Shared native state database (system SQLite3 + CryptoKit). No third-party dependencies.
    .target(
        name: "OpenClawNativeState",
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
            "OpenClawMCP",
            "OpenClawNativeState",
        ],
        resources: [
            .process("Resources"),
        ],
        swiftSettings: [
            .enableUpcomingFeature("StrictConcurrency"),
        ]
    ),
    .target(
        name: "OpenClawChatUI",
        dependencies: [
            "OpenClawKit",
            .product(name: "Markdown", package: "swift-markdown"),
        ],
        swiftSettings: [
            .enableUpcomingFeature("StrictConcurrency"),
        ]
    ),
    // Optional GRDB-backed offline chat store; apps that do not link this product never compile GRDB.
    .target(
        name: "OpenClawChatStore",
        dependencies: [
            "OpenClawChatUI",
            .product(name: "GRDB", package: "GRDB.swift"),
        ],
        swiftSettings: [
            .enableUpcomingFeature("StrictConcurrency"),
        ]
    ),
    // App Intents integration (entities, intents, and the experimental model-delegation trait).
    .target(
        name: "OpenClawAppIntents",
        dependencies: ["OpenClawKit"],
        swiftSettings: [
            .enableUpcomingFeature("StrictConcurrency"),
        ]
    ),
    .testTarget(
        name: "OpenClawKitTests",
        dependencies: [
            "OpenClawKit",
            "OpenClawChatUI",
            "OpenClawGateway",
            "OpenClawCore",
            "OpenClawProtocol",
            "OpenClawModels",
            "OpenClawNativeState",
            "OpenClawMCP",
            "OpenClawAppIntents",
            "OpenClawChatStore",
        ],
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
#endif

targets += [
    .testTarget(
        name: "OpenClawLinuxRuntimeTests",
        dependencies: [
            "OpenClawCore",
            "OpenClawProtocol",
            "OpenClawModels",
            "OpenClawGateway",
            "OpenClawAgents",
            "OpenClawChannels",
            "OpenClawMemory",
            "OpenClawMedia",
            "OpenClawSkills",
            "OpenClawPlugins",
            "OpenClawMCP",
        ],
        swiftSettings: [
            .enableExperimentalFeature("SwiftTesting"),
        ]
    ),
]

let package = Package(
    name: "OpenClawKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v26),
        .watchOS(.v10),
    ],
    products: products,
    traits: [
        .trait(
            name: "ExperimentalAppleModelDelegation",
            description: """
            Experimental: compiles the OpenClawAppIntents model-delegation surface built on the \
            underscored AppIntents 27 `_ModelDelegationIntent` API. Off by default; the API is \
            unstable and may change or disappear in any Apple SDK update.
            """
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/OpenDive/OpenAIKit.git", exact: "3.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.5.0"),
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            revision: "a654a899a0e2802bf66429214e8ebc51c397c4d9"
        ),
        // Markdown parsing for OpenClawChatUI (Apache-2.0; swift-cmark is BSD-2-Clause).
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"),
        // SQLite toolkit for the optional OpenClawChatStore product (MIT). Resolved on every
        // platform, but only compiled when an app links OpenClawChatStore.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: targets
)
