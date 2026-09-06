import Darwin
import Foundation

/// Executable performance budgets. A failing gate is a failing test.
///
/// Budgets are defined in `docs/SPEC.md` section "Performance". Change them there first.
public enum PerfGate {
    /// Fixed budgets from the spec. Milliseconds unless stated otherwise.
    public enum Budget {
        public static let coldLaunchToInteractive: Double = 300
        public static let keystrokeToListUpdate: Double = 16
        /// The core's share of PF-2: a `SearchIndex.query` over 20k notes, leaving 12 ms of the
        /// 16 ms keystroke budget for the table reload (`docs/PLAN.md`, M1.4).
        public static let coreQuery20k: Double = 4
        public static let editorKeystrokeToRedraw: Double = 8
        public static let fullIndex20k: Double = 2000
        /// PF-5: resident memory after a full index of 20k notes. Megabytes.
        public static let memoryAfterIndex20kMB: Double = 200
    }

    /// Note count the budgets are measured against.
    public static let referenceNoteCount = 20_000

    /// Set `MDNOTES_SKIP_PERF=1` to skip perf gates (used by `scripts/check.sh quick`).
    public static var isSkipped: Bool {
        ProcessInfo.processInfo.environment["MDNOTES_SKIP_PERF"] == "1"
    }

    /// Runs `body` `iterations` times and returns the median wall-clock time in milliseconds.
    public static func medianMilliseconds(iterations: Int = 5, _ body: () throws -> Void) rethrows -> Double {
        precondition(iterations > 0)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// The calling process's resident set size in bytes, from `task_info(MACH_TASK_BASIC_INFO)`,
    /// or nil if the kernel refuses. This is what PF-5 measures.
    public static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(task_self_trap(), task_flavor_t(MACH_TASK_BASIC_INFO), words, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    /// Hands every freed malloc page back to the kernel so `residentMemoryBytes()` reflects live
    /// allocations rather than the high-water mark of earlier work in the same process.
    public static func releaseFreedMemory() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// `residentMemoryBytes()` in megabytes (1 MB = 1,048,576 bytes).
    public static func residentMemoryMB() -> Double? {
        residentMemoryBytes().map { Double($0) / 1_048_576 }
    }
}
