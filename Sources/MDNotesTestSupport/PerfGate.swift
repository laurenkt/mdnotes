import Foundation

/// Executable performance budgets. A failing gate is a failing test.
///
/// Budgets are defined in `docs/SPEC.md` section "Performance". Change them there first.
public enum PerfGate {
    /// Fixed budgets from the spec. Milliseconds.
    public enum Budget {
        public static let coldLaunchToInteractive: Double = 300
        public static let keystrokeToListUpdate: Double = 16
        public static let editorKeystrokeToRedraw: Double = 8
        public static let fullIndex20k: Double = 2000
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
}
