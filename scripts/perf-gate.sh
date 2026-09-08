#!/usr/bin/env bash
# One perf gate, judged load-aware. Called by scripts/check.sh for every *PerfTests class.
#
#   scripts/perf-gate.sh <class>
#
# Perf gates are wall-clock measurements on one machine (ADR-0007), so a busy machine fails
# them without any regression in the code, and the retry-once rule of ADR-0016 on its own
# cannot tell the two apart (I-6). This script adds two things around that rule:
#
# - Attempts run under a machine-wide lock, so two check.sh runs never measure at once.
# - An attempt that fails while the 1-minute load average, read before and after it, was
#   above MDNOTES_PERF_LOAD_LIMIT (default: half the cores) is inconclusive. It does not count
#   towards the two failures that fail the gate; the script waits for the load to drop below
#   the limit (up to MDNOTES_PERF_LOAD_WAIT seconds, default 300) and runs again. At most
#   two attempts are set aside this way, so a machine that never quietens still gets a
#   verdict: the attempts after that count whatever the load.
#
# Verdict, as before: a pass exits 0; a conclusive failure followed by a pass exits 0 and
# records a flaky entry in docs/ISSUES.md; two conclusive failures exit 1. A pass never needs
# the load, so a quiet run costs nothing extra.
#
# The commands it runs can be substituted for the test that covers it
# (Tests/MDNotesAppTests/PerfGateScriptTests.swift):
#   MDNOTES_PERF_RUNNER   runs one attempt; given the class as its argument
#   MDNOTES_PERF_LOAD     prints the 1-minute load average
#   MDNOTES_PERF_RECORD   records a flaky entry; given the record-issue.sh arguments
#   MDNOTES_PERF_LOCK     the lock file
#   MDNOTES_PERF_LOAD_POLL  seconds between load readings while waiting (default 10)
set -euo pipefail
cd "$(dirname "$0")/.."
class="${1:?perf test class}"

runner="${MDNOTES_PERF_RUNNER:-}"
load_command="${MDNOTES_PERF_LOAD:-}"
record="${MDNOTES_PERF_RECORD:-scripts/record-issue.sh}"
lock="${MDNOTES_PERF_LOCK:-${TMPDIR:-/tmp}/mdnotes-perf-gate.lock}"
load_wait="${MDNOTES_PERF_LOAD_WAIT:-300}"
load_poll="${MDNOTES_PERF_LOAD_POLL:-10}"
if [ -z "${MDNOTES_PERF_LOAD_LIMIT:-}" ]; then
    cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    load_limit=$(( cores / 2 ))
    [ "$load_limit" -lt 1 ] && load_limit=1
else
    load_limit="$MDNOTES_PERF_LOAD_LIMIT"
fi

run_attempt() {
    if [ -n "$runner" ]; then
        "$runner" "$class"
    else
        swift test -c release --skip-build --filter "$class"
    fi
}

read_load() {
    if [ -n "$load_command" ]; then
        "$load_command"
    else
        sysctl -n vm.loadavg | awk '{print $2}'
    fi
}

# `above A B` succeeds when load A is above limit B; `larger A B` prints the larger.
above() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
larger() { awk -v a="$1" -v b="$2" 'BEGIN { print (a > b) ? a : b }'; }

# shlock takes the lock atomically and treats a lock whose pid is dead as free.
have_lock=0
take_lock() {
    local waited=0
    until shlock -f "$lock" -p $$; do
        if [ "$waited" -eq 0 ]; then
            echo "perf gate: another perf gate holds $lock; waiting for it"
        fi
        if [ "$waited" -ge "$load_wait" ]; then
            echo "perf gate: still locked after ${load_wait}s; measuring anyway" >&2
            return 0
        fi
        sleep "$load_poll"
        waited=$(( waited + load_poll ))
    done
    have_lock=1
    trap 'rm -f "$lock"' EXIT
}

release_lock() {
    [ "$have_lock" -eq 1 ] && rm -f "$lock"
    have_lock=0
    trap - EXIT
}

wait_for_load() {
    local waited=0 load
    while :; do
        load="$(read_load)"
        if ! above "$load" "$load_limit"; then
            echo "perf gate: load average $load is under the limit of $load_limit; retrying"
            return 0
        fi
        if [ "$waited" -ge "$load_wait" ]; then
            echo "perf gate: load average still $load after ${load_wait}s; the next attempt counts whatever the load" >&2
            return 0
        fi
        if [ "$waited" -eq 0 ]; then
            echo "perf gate: load average $load is above the limit of $load_limit; waiting up to ${load_wait}s for it to drop"
        fi
        sleep "$load_poll"
        waited=$(( waited + load_poll ))
    done
}

failures=0
inconclusive=0
first_failure_log=""
cleanup_logs() { [ -n "$first_failure_log" ] && rm -f "$first_failure_log"; return 0; }

while :; do
    take_lock
    load_before="$(read_load)"
    log="$(mktemp)"
    status=0
    run_attempt 2>&1 | tee "$log" || status=$?
    load_after="$(read_load)"
    release_lock

    if [ "$status" -eq 0 ]; then
        if [ "$failures" -eq 1 ]; then
            # Failed then passed on a quiet machine: a flake. Let the commit through but record
            # it so the flake gets its own task (ADR-0016).
            failed="$(grep -oE "\-\[[A-Za-z0-9_.]+ [A-Za-z0-9_]+\]' failed" "$first_failure_log" | head -1 | sed -E "s/'.*//; s/^-\[//; s/\]$//")"
            detail="$(grep -E 'XCTAssert|median|budget' "$first_failure_log" | head -3 | tr '\n' ' ' | cut -c1-300)"
            "$record" flaky "$class" "${failed:-unknown test} failed once and passed on retry. First run: ${detail:-no detail captured}"
        fi
        rm -f "$log"
        cleanup_logs
        exit 0
    fi

    peak="$(larger "$load_before" "$load_after")"
    if [ "$inconclusive" -lt 2 ] && above "$peak" "$load_limit"; then
        inconclusive=$(( inconclusive + 1 ))
        rm -f "$log"
        echo "perf gate: $class failed with the load average at $peak (limit $load_limit); not counted, the machine was busy" >&2
        wait_for_load
        continue
    fi

    failures=$(( failures + 1 ))
    if [ "$failures" -eq 1 ]; then
        first_failure_log="$log"
        echo "perf gate: $class failed (load average $peak); retrying once" >&2
        continue
    fi
    rm -f "$log"
    cleanup_logs
    echo "perf gate $class failed twice (load average $peak, limit $load_limit)" >&2
    exit 1
done
