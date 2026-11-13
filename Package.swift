// swift-tools-version: 6.2
import PackageDescription

let ui: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Plinth",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Plinth", targets: ["Plinth"]),
        // The whole app as a library, for the Xcode app target in Plinth.xcodeproj.
        .library(name: "PlinthApp", targets: ["PlinthApp"]),
    ],
    targets: [
        // Frozen shared contracts: value types and protocols. No logic beyond trivial helpers.
        .target(name: "PlinthModel"),
        // Pure logic, one owner each.
        .target(name: "PlinthRules", dependencies: ["PlinthModel"]),
        .target(name: "PlinthFade", dependencies: ["PlinthModel"]),
        .target(name: "PlinthLayout", dependencies: ["PlinthModel"]),
        .target(name: "PlinthStore", dependencies: ["PlinthModel"]),
        // On-device AI (Foundation Models, NaturalLanguage) behind PlinthModel protocols.
        .target(name: "PlinthAI", dependencies: ["PlinthModel"]),
        // iCloud sync: record mapping, merge rules, transports (in-memory and CloudKit).
        .target(name: "PlinthSync", dependencies: ["PlinthModel"]),
        // User settings: model, persistence, search engines, clearing ranges.
        .target(name: "PlinthSettings", dependencies: ["PlinthModel", "PlinthRules"]),
        // Bookmark and history import from Safari and Chrome.
        .target(name: "PlinthImport", dependencies: ["PlinthModel", "PlinthRules", "PlinthStore"]),
        // UI and WebKit.
        .target(name: "PlinthBarUI", dependencies: ["PlinthModel"], swiftSettings: ui),
        .target(name: "PlinthPanels", dependencies: ["PlinthModel"], swiftSettings: ui),
        .target(name: "PlinthWeb", dependencies: ["PlinthModel", "PlinthSettings"], resources: [.process("Resources")], swiftSettings: ui),
        // The app shell: wires the modules together.
        .target(
            name: "PlinthApp",
            dependencies: ["PlinthModel", "PlinthRules", "PlinthFade", "PlinthLayout", "PlinthStore", "PlinthBarUI", "PlinthPanels", "PlinthWeb", "PlinthAI", "PlinthSync", "PlinthSettings", "PlinthImport"],
            swiftSettings: ui
        ),
        // SwiftPM entry point; Scripts/bundle.sh wraps it in Plinth.app.
        .executableTarget(name: "Plinth", dependencies: ["PlinthApp"], swiftSettings: ui),
        .testTarget(name: "PlinthRulesTests", dependencies: ["PlinthRules"]),
        .testTarget(name: "PlinthFadeTests", dependencies: ["PlinthFade"]),
        .testTarget(name: "PlinthLayoutTests", dependencies: ["PlinthLayout"]),
        .testTarget(name: "PlinthStoreTests", dependencies: ["PlinthStore"]),
        .testTarget(name: "PlinthAITests", dependencies: ["PlinthAI"]),
        .testTarget(name: "PlinthSyncTests", dependencies: ["PlinthSync"]),
        .testTarget(name: "PlinthSettingsTests", dependencies: ["PlinthSettings"]),
        .testTarget(name: "PlinthWebTests", dependencies: ["PlinthWeb"]),
        .testTarget(name: "PlinthImportTests", dependencies: ["PlinthImport"]),
    ]
)
