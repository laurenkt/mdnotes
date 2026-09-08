import Foundation
import XCTest

/// `scripts/perf-gate.sh` runs one `*PerfTests` class for `scripts/check.sh` and decides
/// whether a failure counts: the retry-once rule of ADR-0016, made load-aware (I-6). These
/// tests run the script with its runner, load reading and issue recorder replaced by small
/// scripts, so the verdicts are covered without a release build.
final class PerfGateScriptTests: XCTestCase {
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private struct Verdict {
        let status: Int32
        let attempts: Int
        let records: [String]
        let output: String
    }

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdnotes-perfgate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeScript(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs the gate with a runner whose attempts exit with `statuses` in turn (the last one
    /// repeating) and a load reading that returns `loads` in turn (the last one repeating).
    /// The load limit is 4; waiting for the load to drop is capped at one second.
    private func runGate(statuses: [Int32], loads: [Double]) throws -> Verdict {
        let statusFile = directory.appendingPathComponent("statuses")
        let loadFile = directory.appendingPathComponent("loads")
        let attemptsFile = directory.appendingPathComponent("attempts")
        let recordsFile = directory.appendingPathComponent("records")
        try statuses.map(String.init).joined(separator: "\n").write(to: statusFile, atomically: true, encoding: .utf8)
        try loads.map { String(format: "%.2f", $0) }.joined(separator: "\n")
            .write(to: loadFile, atomically: true, encoding: .utf8)
        try "".write(to: attemptsFile, atomically: true, encoding: .utf8)
        try "".write(to: recordsFile, atomically: true, encoding: .utf8)

        // Each call pops the first line of its file, keeping the last line forever.
        let pop = """
            f="$1"
            first="$(head -n 1 "$f")"
            if [ "$(wc -l < "$f" | tr -d ' ')" -gt 0 ]; then
                tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"
            fi
            printf '%s\\n' "$first"
            """
        let popper = try writeScript("pop.sh", pop)
        let runner = try writeScript(
            "runner.sh",
            """
            echo "$1" >> "\(attemptsFile.path)"
            status="$("\(popper.path)" "\(statusFile.path)")"
            echo "Test Case '-[MDNotesAppTests.\\$1 testPF9_fake]' started."
            if [ "$status" -ne 0 ]; then
                echo "PERF PF-9 fake: median 9.00 ms (budget 8.00 ms)"
                echo "Test Case '-[MDNotesAppTests.$1 testPF9_fake]' failed (1.0 seconds)."
            fi
            exit "$status"
            """)
        let load = try writeScript("load.sh", "\"\(popper.path)\" \"\(loadFile.path)\"")
        let record = try writeScript(
            "record.sh", "printf '%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" >> \"\(recordsFile.path)\"")

        let process = Process()
        process.executableURL = Self.repoRoot.appendingPathComponent("scripts/perf-gate.sh")
        process.arguments = ["FakePerfTests"]
        process.currentDirectoryURL = Self.repoRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MDNOTES_PERF_RUNNER": runner.path,
            "MDNOTES_PERF_LOAD": load.path,
            "MDNOTES_PERF_RECORD": record.path,
            "MDNOTES_PERF_LOCK": directory.appendingPathComponent("gate.lock").path,
            "MDNOTES_PERF_LOAD_LIMIT": "4",
            "MDNOTES_PERF_LOAD_WAIT": "1",
            "MDNOTES_PERF_LOAD_POLL": "1",
        ]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let attempts = try String(contentsOf: attemptsFile, encoding: .utf8)
            .split(separator: "\n").count
        let records = try String(contentsOf: recordsFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        return Verdict(
            status: process.terminationStatus, attempts: attempts, records: records,
            output: String(decoding: data, as: UTF8.self))
    }

    func testI6_passOnAQuietMachineRunsOnceAndRecordsNothing() throws {
        let verdict = try runGate(statuses: [0], loads: [2])
        XCTAssertEqual(verdict.status, 0, verdict.output)
        XCTAssertEqual(verdict.attempts, 1)
        XCTAssertEqual(verdict.records, [])
    }

    func testI6_passOnABusyMachineIsAPass() throws {
        let verdict = try runGate(statuses: [0], loads: [20])
        XCTAssertEqual(verdict.status, 0, verdict.output)
        XCTAssertEqual(verdict.attempts, 1)
        XCTAssertEqual(verdict.records, [])
    }

    func testI6_failThenPassOnAQuietMachineIsAFlakeAndRecorded() throws {
        let verdict = try runGate(statuses: [1, 0], loads: [2])
        XCTAssertEqual(verdict.status, 0, verdict.output)
        XCTAssertEqual(verdict.attempts, 2)
        XCTAssertEqual(verdict.records.count, 1)
        let record = try XCTUnwrap(verdict.records.first)
        XCTAssertTrue(record.hasPrefix("flaky|FakePerfTests|"), record)
        XCTAssertTrue(
            record.contains("MDNotesAppTests.FakePerfTests testPF9_fake failed once and passed on retry"), record)
        XCTAssertTrue(record.contains("median 9.00 ms"), record)
    }

    func testI6_twoFailuresOnAQuietMachineFailTheGate() throws {
        let verdict = try runGate(statuses: [1], loads: [2])
        XCTAssertEqual(verdict.status, 1, verdict.output)
        XCTAssertEqual(verdict.attempts, 2)
        XCTAssertEqual(verdict.records, [])
    }

    func testI6_failureUnderLoadIsNotCountedAndTheLaterPassIsNotAFlake() throws {
        // Load 20 before and after the first attempt, 2 from then on: the first failure is the
        // machine's, the pass that follows once it quietens is the verdict.
        let verdict = try runGate(statuses: [1, 0], loads: [20, 20, 2])
        XCTAssertEqual(verdict.status, 0, verdict.output)
        XCTAssertEqual(verdict.attempts, 2)
        XCTAssertEqual(verdict.records, [], "a failure under load is not a flake")
        XCTAssertTrue(verdict.output.contains("not counted"), verdict.output)
    }

    func testI6_failureUnderLoadThenTwoQuietFailuresFailTheGate() throws {
        let verdict = try runGate(statuses: [1], loads: [20, 20, 2])
        XCTAssertEqual(verdict.status, 1, verdict.output)
        XCTAssertEqual(verdict.attempts, 3, "one attempt set aside for load, then the two that count")
        XCTAssertEqual(verdict.records, [])
    }

    func testI6_loadThatNeverDropsStillReachesAVerdict() throws {
        // Two attempts are set aside for load at most; the machine stays busy, so the two
        // after that count and fail the gate.
        let verdict = try runGate(statuses: [1], loads: [20])
        XCTAssertEqual(verdict.status, 1, verdict.output)
        XCTAssertEqual(verdict.attempts, 4)
        XCTAssertEqual(verdict.records, [])
        XCTAssertTrue(verdict.output.contains("whatever the load"), verdict.output)
    }

    func testI6_loadReadAfterTheAttemptCountsToo() throws {
        // Quiet before the attempt, busy after it: something started during the measurement.
        let verdict = try runGate(statuses: [1, 0], loads: [2, 20, 2])
        XCTAssertEqual(verdict.status, 0, verdict.output)
        XCTAssertEqual(verdict.attempts, 2)
        XCTAssertEqual(verdict.records, [])
    }

    func testI6_checkRunsEveryPerfClassThroughTheGateScript() throws {
        let check = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("scripts/check.sh"), encoding: .utf8)
        XCTAssertTrue(check.contains("scripts/perf-gate.sh \"$class\""), "check.sh does not use perf-gate.sh")
    }
}
