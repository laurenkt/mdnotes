import Foundation

/// A scheduled autosave (E-4). Cancelling one that has already fired, or was cancelled
/// before, does nothing.
@MainActor
public protocol AutosaveTimer: AnyObject {
    func cancel()
}

/// The clock the autosave delay runs on (E-4). The app uses `SystemAutosaveClock`; tests
/// substitute one they advance by hand, so "300 ms after the last edit" is asserted exactly
/// instead of slept for.
@MainActor
public protocol AutosaveClock: AnyObject {
    var now: Date { get }

    /// Runs `action` once on the main thread when the clock reaches `deadline`, or as soon as
    /// possible if it already has. The returned timer cancels the call.
    func schedule(at deadline: Date, _ action: @escaping @MainActor () -> Void) -> any AutosaveTimer
}

/// The wall clock, firing through the main dispatch queue.
@MainActor
public final class SystemAutosaveClock: AutosaveClock {
    public init() {}

    public var now: Date { Date() }

    public func schedule(at deadline: Date, _ action: @escaping @MainActor () -> Void) -> any AutosaveTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        let delay = max(0, deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemTimer(item)
    }

    private final class WorkItemTimer: AutosaveTimer {
        private let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) {
            self.item = item
        }

        func cancel() {
            item.cancel()
        }
    }
}
