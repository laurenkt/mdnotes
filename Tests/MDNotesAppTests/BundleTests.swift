import Foundation
import XCTest

/// The app bundle is assembled by `scripts/bundle.sh` with an Info.plist emitted by
/// `scripts/info-plist.sh`. These tests run the plist script directly, so they cover the
/// bundle's metadata without needing a release build (P-3, P-4).
final class BundleTests: XCTestCase {
    private static let repoRoot: URL = {
        // Tests/MDNotesAppTests/BundleTests.swift -> repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    /// Runs `scripts/info-plist.sh` with the given environment and returns its stdout.
    private func generatedPlist(environment: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = Self.repoRoot.appendingPathComponent("scripts/info-plist.sh")
        process.currentDirectoryURL = Self.repoRoot
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "info-plist.sh failed")
        return data
    }

    /// Runs `plutil -lint` on the data and returns the exit status.
    private func plutilLintStatus(_ data: Data) throws -> Int32 {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDNotes-\(UUID().uuidString).plist")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-lint", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func dictionary(from data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any], "Info.plist root is not a dictionary")
    }

    func testP4_generatedInfoPlistPassesPlutilLint() throws {
        let data = try generatedPlist()
        XCTAssertEqual(try plutilLintStatus(data), 0, "plutil -lint rejected the Info.plist")
    }

    func testP4_generatedInfoPlistHasLaunchKeys() throws {
        let plist = try dictionary(from: try generatedPlist(environment: ["MDNOTES_VERSION": "9.9.9"]))
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "MDNotes")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "dev.laurenkt.mdnotes")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "9.9.9")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "9.9.9")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "26.0")
        XCTAssertNil(plist["CFBundleIconFile"], "no icon key unless an icon is bundled")
    }

    func testP4_generatedInfoPlistCarriesIconWhenProvided() throws {
        let data = try generatedPlist(environment: ["MDNOTES_ICON_FILE": "AppIcon"])
        XCTAssertEqual(try plutilLintStatus(data), 0)
        let plist = try dictionary(from: data)
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
    }
}
