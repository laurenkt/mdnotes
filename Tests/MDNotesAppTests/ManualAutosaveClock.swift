import Foundation
import MDNotesApp

/// An `AutosaveClock` that only moves when a test says so (E-4). Timers fire, in deadline
/// order, from inside `advance(by:)`, on the main thread, so a test asserts what happened
/// 299 ms and 300 ms after an edit without waiting for either.
@MainActor
final class ManualAutosaveClock: AutosaveClock {
    private(set) var now: Date
    private var pending: [Entry] = []
    private var nextSequence = 0

    init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.now = now
    }

    /// Timers scheduled and neither fired nor cancelled.
    var pendingCount: Int { pending.count }

    func schedule(at deadline: Date, _ action: @escaping @MainActor () -> Void) -> any AutosaveTimer {
        nextSequence += 1
        let entry = Entry(clock: self, deadline: deadline, sequence: nextSequence, action: action)
        pending.append(entry)
        pending.sort { ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence) }
        return entry
    }

    /// Moves the clock forward and fires every timer whose deadline has been reached.
    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        while let next = pending.first, next.deadline <= now {
            pending.removeFirst()
            next.action()
        }
    }

    private func cancel(_ entry: Entry) {
        pending.removeAll { $0 === entry }
    }

    final class Entry: AutosaveTimer {
        private weak var clock: ManualAutosaveClock?
        let deadline: Date
        let sequence: Int
        let action: @MainActor () -> Void

        init(clock: ManualAutosaveClock, deadline: Date, sequence: Int, action: @escaping @MainActor () -> Void) {
            self.clock = clock
            self.deadline = deadline
            self.sequence = sequence
            self.action = action
        }

        func cancel() {
            clock?.cancel(self)
        }
    }
}
