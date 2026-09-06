# ADR-0002: Pure SwiftPM, no Xcode project

Status: accepted, 2026-09-06

## Decision
The repo is a SwiftPM package. `swift build`, `swift test`, `swift run` are the whole workflow.
`scripts/bundle.sh` assembles `MDNotes.app` from the release binary and a generated Info.plist.
No `.xcodeproj` or `.xcworkspace` may be created, committed, or used; `xcodebuild` and
`xcodegen` are blocked by hooks.

## Why
The owner wants to build from the CLI without opening Xcode. For agent-generated code, a
checked-in `pbxproj` is the single most common merge and hallucination hazard, and generated
projects add a tool dependency for no benefit in a three-view app. Xcode.app stays installed
only for the SDK and toolchain.

## Consequences
App-bundle concerns (Info.plist, icon, signing) live in a shell script. Perf tests run via
`swift test -c release`. No Instruments integration by default; use `xcrun xctrace` if needed.
