// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "MDNotes",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MDNotes", targets: ["MDNotes"]),
        .library(name: "MDNotesCore", targets: ["MDNotesCore"]),
    ],
    targets: [
        // Pure logic: index, search, links, tags, file store. Foundation only. No AppKit.
        .target(
            name: "MDNotesCore",
            swiftSettings: strict
        ),
        // AppKit layer: window, controllers, views. Testable headlessly.
        .target(
            name: "MDNotesApp",
            dependencies: ["MDNotesCore"],
            swiftSettings: strict
        ),
        // Thin entry point. Nothing lives here except main.swift.
        .executableTarget(
            name: "MDNotes",
            dependencies: ["MDNotesApp"],
            swiftSettings: strict
        ),
        // Shared test helpers: synthetic library generator, perf gate.
        .target(
            name: "MDNotesTestSupport",
            dependencies: ["MDNotesCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MDNotesCoreTests",
            dependencies: ["MDNotesCore", "MDNotesTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MDNotesAppTests",
            dependencies: ["MDNotesApp", "MDNotesTestSupport"],
            swiftSettings: strict
        ),
    ]
)
