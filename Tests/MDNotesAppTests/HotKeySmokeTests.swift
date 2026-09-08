import AppKit
import Carbon.HIToolbox
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the global hotkey (W-3, PR-1): the default Ctrl-Cmd-N, registered
/// with Carbon at launch and remembered in `UserDefaults`; a press activates the app, brings
/// the window forward and selects the query, or hides the window when it is up and the app is
/// active; the recorder in Preferences changes, stores and re-registers it.
///
/// A press cannot be synthesised without posting events system-wide, so the press path is
/// driven through `GlobalHotKey.fire()`, which is what the Carbon handler calls. That the
/// registration is real is checked against Carbon itself: a second registration of the same
/// combination in this process is declined with `eventHotKeyExistsErr` until the first is
/// released. Activation is observed through `AppDelegate.activateApp`, and whether the app is
/// active is told through `AppDelegate.isAppActive`, since a test process is never the active
/// application.
@MainActor
final class HotKeySmokeTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory
    private let alpha = NoteID(relativePath: "Alpha.md")

    private let keys = [
        HotKeyPreference.keyCodeDefaultsKey, HotKeyPreference.modifiersDefaultsKey,
        LibraryRootPreference.defaultsKey, MainView.listHeightDefaultsKey,
    ]

    private let controlCommandN = HotKey(keyCode: UInt16(kVK_ANSI_N), modifiers: [.control, .command])
    private let controlOptionSpace = HotKey(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])
    private let commandShiftF5 = HotKey(keyCode: UInt16(kVK_F5), modifiers: [.command, .shift])

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mdnotes-hotkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha body".write(to: root.appendingPathComponent("Alpha.md"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Fixture

    /// Main-actor box so a delegate can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class DelegateBox {
        let delegate: AppDelegate
        init(_ delegate: AppDelegate) { self.delegate = delegate }
    }

    /// A delegate launched against `root` through the real launch path, with the library
    /// ready. Its hotkey is released at teardown, so the next test can register it again.
    private func launch() async throws -> AppDelegate {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: root)
        let box = DelegateBox(delegate)
        addTeardownBlock {
            await MainActor.run {
                box.delegate.globalHotKey?.unregister()
                box.delegate.libraryController?.stop()
                box.delegate.preferencesWindowController?.close()
                box.delegate.mainWindowController?.close()
            }
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let library = try XCTUnwrap(delegate.libraryController)
        await waitUntil("library ready") { library.phase == .ready }
        return delegate
    }

    private func keyDown(_ hotKey: HotKey, characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: hotKey.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: hotKey.keyCode))
    }

    /// Sends a key press the way the running app's event loop would: the key window's key
    /// equivalents first, then the window's own dispatch to its first responder.
    private func press(_ hotKey: HotKey, characters: String, in window: NSWindow) throws {
        let event = try keyDown(hotKey, characters: characters, in: window)
        if window.performKeyEquivalent(with: event) { return }
        window.sendEvent(event)
    }

    /// Whether `hotKey` is free in this process: a registration of it succeeds. The trial
    /// registration is released again before this returns.
    private func carbonAccepts(_ hotKey: HotKey) -> Bool {
        let trial = GlobalHotKey()
        defer { trial.unregister() }
        do {
            try trial.register(hotKey)
            return true
        } catch {
            return false
        }
    }

    // MARK: - W-3: the default is Ctrl-Cmd-N

    func testW3_defaultHotKeyIsControlCommandN() {
        XCTAssertEqual(HotKey.default, controlCommandN)
        XCTAssertEqual(HotKey.default.keyCode, 45)
        XCTAssertEqual(HotKey.default.carbonModifiers, UInt32(controlKey | cmdKey))
        XCTAssertEqual(HotKey.default.displayString, "⌃⌘N")
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN, "nothing stored")
        XCTAssertEqual(AppDelegate().hotKey, controlCommandN)
    }

    func testW3_displayStringNamesTheModifiersInOrderAndTheKey() {
        XCTAssertEqual(commandShiftF5.displayString, "⇧⌘F5")
        XCTAssertEqual(controlOptionSpace.displayString, "⌃⌥Space")
        XCTAssertEqual(HotKey(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift]).displayString, "⇧⌘A")
        XCTAssertEqual(HotKey(keyCode: UInt16(kVK_UpArrow), modifiers: [.option]).displayString, "⌥↑")
        XCTAssertEqual(HotKey(keyCode: UInt16(kVK_Return), modifiers: [.control]).displayString, "⌃↩")
        XCTAssertEqual(
            HotKey(keyCode: UInt16(kVK_ANSI_1), modifiers: [.control, .option, .shift, .command]).displayString,
            "⌃⌥⇧⌘1")
    }

    func testW3_hotKeyFromAKeyPressNeedsCommandControlOrOption() throws {
        let window = try XCTUnwrap(makeMainWindowController().window)
        XCTAssertNil(HotKey(recording: try keyDown(HotKey(keyCode: 45, modifiers: []), characters: "n", in: window)))
        XCTAssertNil(
            HotKey(recording: try keyDown(HotKey(keyCode: 45, modifiers: [.shift]), characters: "N", in: window)),
            "Shift alone would swallow typing")
        XCTAssertEqual(HotKey(recording: try keyDown(controlCommandN, characters: "n", in: window)), controlCommandN)
        XCTAssertEqual(
            HotKey(recording: try keyDown(HotKey(keyCode: 45, modifiers: [.option]), characters: "n", in: window)),
            HotKey(keyCode: 45, modifiers: [.option]))

        // Flags that are not modifier keys are dropped, so an arrow key records as the key.
        let arrow = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: UInt16(kVK_UpArrow)))
        XCTAssertEqual(HotKey(recording: arrow), HotKey(keyCode: UInt16(kVK_UpArrow), modifiers: [.command]))
        XCTAssertEqual(HotKey(keyCode: 45, modifiers: [.command, .capsLock, .function]).modifiers, [.command])
    }

    // MARK: - W-3, PR-1: the preference

    func testW3_hotKeyPreferenceIsStoredAndReadBack() {
        HotKeyPreference.set(controlOptionSpace, in: .standard)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: HotKeyPreference.keyCodeDefaultsKey), Int(kVK_Space))
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: HotKeyPreference.modifiersDefaultsKey),
            Int(NSEvent.ModifierFlags([.control, .option]).rawValue))
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlOptionSpace)

        // A fresh delegate, as the next launch would make, takes the stored combination.
        XCTAssertEqual(AppDelegate().hotKey, controlOptionSpace)
    }

    func testW3_unusableStoredValuesFallBackToTheDefault() {
        // One half alone is not a hotkey.
        UserDefaults.standard.set(Int(kVK_Space), forKey: HotKeyPreference.keyCodeDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)
        UserDefaults.standard.removeObject(forKey: HotKeyPreference.keyCodeDefaultsKey)
        UserDefaults.standard.set(
            Int(NSEvent.ModifierFlags.command.rawValue), forKey: HotKeyPreference.modifiersDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)

        // Shift alone, or no modifier, is not acceptable.
        UserDefaults.standard.set(Int(kVK_Space), forKey: HotKeyPreference.keyCodeDefaultsKey)
        UserDefaults.standard.set(
            Int(NSEvent.ModifierFlags.shift.rawValue), forKey: HotKeyPreference.modifiersDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)
        UserDefaults.standard.set(0, forKey: HotKeyPreference.modifiersDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)

        // Flags outside the modifier mask, a key code out of range, or the wrong type.
        UserDefaults.standard.set(
            Int(NSEvent.ModifierFlags([.command, .function]).rawValue), forKey: HotKeyPreference.modifiersDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)
        UserDefaults.standard.set(
            Int(NSEvent.ModifierFlags.command.rawValue), forKey: HotKeyPreference.modifiersDefaultsKey)
        UserDefaults.standard.set(999, forKey: HotKeyPreference.keyCodeDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)
        UserDefaults.standard.set(-1, forKey: HotKeyPreference.keyCodeDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)
        UserDefaults.standard.set("space", forKey: HotKeyPreference.keyCodeDefaultsKey)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)

        // A usable pair is read.
        UserDefaults.standard.set(Int(kVK_Space), forKey: HotKeyPreference.keyCodeDefaultsKey)
        XCTAssertEqual(
            HotKeyPreference.hotKey(from: .standard), HotKey(keyCode: UInt16(kVK_Space), modifiers: [.command]))
    }

    // MARK: - W-3: registered with Carbon at launch

    func testW3_launchRegistersTheDefaultHotKeyWithCarbon() async throws {
        XCTAssertTrue(carbonAccepts(controlCommandN), "free before launch")

        let delegate = try await launch()
        let hotKey = try XCTUnwrap(delegate.globalHotKey)
        XCTAssertTrue(hotKey.isRegistered)
        XCTAssertEqual(hotKey.hotKey, controlCommandN)
        XCTAssertEqual(delegate.hotKey, controlCommandN)

        // Carbon has it: a second registration in this process is declined until it is released.
        let other = GlobalHotKey()
        XCTAssertThrowsError(try other.register(controlCommandN)) { error in
            XCTAssertEqual(error as? GlobalHotKey.RegistrationError, .init(status: OSStatus(eventHotKeyExistsErr)))
        }
        XCTAssertFalse(other.isRegistered)
        XCTAssertTrue(carbonAccepts(controlOptionSpace), "another combination is free")

        hotKey.unregister()
        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertNil(hotKey.hotKey)
        XCTAssertNoThrow(try other.register(controlCommandN))
        XCTAssertTrue(other.isRegistered)
        other.unregister()
        XCTAssertTrue(carbonAccepts(controlCommandN))
    }

    func testW3_storedHotKeyIsRegisteredAtTheNextLaunch() async throws {
        HotKeyPreference.set(controlOptionSpace, in: .standard)
        let delegate = try await launch()
        XCTAssertEqual(delegate.hotKey, controlOptionSpace)
        XCTAssertEqual(delegate.globalHotKey?.hotKey, controlOptionSpace)
        XCTAssertFalse(carbonAccepts(controlOptionSpace), "taken by the launch")
        XCTAssertTrue(carbonAccepts(controlCommandN), "the default is not registered as well")

        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        XCTAssertEqual(preferences.hotKey, controlOptionSpace)
        XCTAssertEqual(preferences.hotKeyRecorder.title, "⌃⌥Space")
    }

    func testW3_aRegistrationIsReleasedWhenItsOwnerGoes() {
        var owner: GlobalHotKey? = GlobalHotKey()
        XCTAssertNoThrow(try owner?.register(controlOptionSpace))
        XCTAssertFalse(carbonAccepts(controlOptionSpace))
        owner = nil
        XCTAssertTrue(carbonAccepts(controlOptionSpace), "released by deinit")
    }

    func testW3_aDeclinedChangeKeepsThePreviousRegistration() throws {
        let holder = GlobalHotKey()
        try holder.register(controlOptionSpace)
        let subject = GlobalHotKey()
        try subject.register(controlCommandN)

        XCTAssertThrowsError(try subject.register(controlOptionSpace))
        XCTAssertEqual(subject.hotKey, controlCommandN, "still on the old combination")
        XCTAssertFalse(carbonAccepts(controlCommandN), "and Carbon still has it")

        holder.unregister()
        subject.unregister()
    }

    // MARK: - W-3: a press activates the app, brings the window forward and selects the query

    func testW3_pressActivatesTheAppBringsTheWindowForwardAndSelectsTheQuery() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let window = try XCTUnwrap(controller.window)
        var activations = 0
        delegate.activateApp = { activations += 1 }
        delegate.isAppActive = { false }

        // A query is typed, focus has moved to the list, and the window is away.
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()
        controller.listController.select(alpha)
        window.makeFirstResponder(controller.mainView.tableView)
        XCTAssertIdentical(window.firstResponder, controller.mainView.tableView)
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        try XCTUnwrap(delegate.globalHotKey).fire()

        XCTAssertEqual(activations, 1)
        XCTAssertTrue(window.isVisible)
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor())
        XCTAssertIdentical(window.firstResponder, editor, "the search field has focus")
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha", "the query is kept")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 5), "and selected, ready to replace")
        XCTAssertEqual(controller.listController.selectedID, alpha, "the selection is untouched")

        // Pressed again with the window up but another application active: the same, once
        // more, since the press is a summons, not a dismissal (W-3).
        window.makeFirstResponder(controller.mainView.textView)
        delegate.toggleFromHotKey()
        XCTAssertEqual(activations, 2)
        XCTAssertTrue(window.isVisible)
        XCTAssertIdentical(window.firstResponder, controller.mainView.searchField.currentEditor())
        XCTAssertEqual(controller.mainView.searchField.currentEditor()?.selectedRange, NSRange(location: 0, length: 5))
    }

    // MARK: - W-3: pressed with the window up and the app active, the press hides the window

    func testW3_pressTogglesTheWindowHiddenAndShownAgain() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let window = try XCTUnwrap(controller.window)
        let hotKey = try XCTUnwrap(delegate.globalHotKey)
        var activations = 0
        delegate.activateApp = { activations += 1 }
        delegate.isAppActive = { false }

        // Some state to survive the round trip: a query, a selection, focus in the editor.
        controller.mainView.searchField.stringValue = "alpha"
        controller.searchQueryDidChange()
        controller.listController.select(alpha)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(delegate.isMainWindowVisible)

        // Visible but not the active application: the first press summons.
        hotKey.fire()
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(window.isVisible)
        XCTAssertIdentical(window.firstResponder, controller.mainView.searchField.currentEditor())

        // Visible and active: the second press hides. The app is not activated or deactivated,
        // the window is not closed, and nothing in it is disturbed.
        delegate.isAppActive = { true }
        hotKey.fire()
        XCTAssertEqual(activations, 1, "hiding does not activate")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(delegate.isMainWindowVisible)
        XCTAssertEqual(controller.mainView.searchField.stringValue, "alpha")
        XCTAssertEqual(controller.listController.selectedID, alpha)
        XCTAssertEqual(controller.listController.results.map(\.id), [alpha])

        // Hidden, whether or not the app is still active: the third press shows again and
        // focuses the search field with the query selected.
        window.makeFirstResponder(nil)
        hotKey.fire()
        XCTAssertEqual(activations, 2)
        XCTAssertTrue(window.isVisible)
        let editor = try XCTUnwrap(controller.mainView.searchField.currentEditor())
        XCTAssertIdentical(window.firstResponder, editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(controller.listController.selectedID, alpha, "the selection survived the round trip")

        // And once more from active-and-visible: hidden; so the press is a toggle, not a latch.
        hotKey.fire()
        XCTAssertFalse(window.isVisible)
        delegate.isAppActive = { false }
        hotKey.fire()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(activations, 3)
    }

    // MARK: - PR-1, W-3: the recorder in Preferences

    func testPR1_preferencesWindowShowsTheHotKeyRecorder() async throws {
        let delegate = try await launch()
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        let content = try XCTUnwrap(preferences.window?.contentView)
        let recorder = preferences.hotKeyRecorder
        XCTAssertTrue(recorder.isDescendant(of: content))
        XCTAssertTrue(preferences.chooseButton.isDescendant(of: content), "the folder row is still there")
        XCTAssertEqual(recorder.title, "⌃⌘N")
        XCTAssertEqual(recorder.hotKey, controlCommandN)
        XCTAssertEqual(recorder.defaultHotKey, controlCommandN)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.acceptsFirstResponder)

        // Laid out below the folder row, within the window.
        preferences.window?.layoutIfNeeded()
        let recorderFrame = recorder.convert(recorder.bounds, to: content)
        let chooseFrame = preferences.chooseButton.convert(preferences.chooseButton.bounds, to: content)
        XCTAssertGreaterThan(recorderFrame.width, 0)
        XCTAssertLessThan(recorderFrame.maxY, chooseFrame.minY, "below the folder row (flipped: y grows upward)")
        XCTAssertTrue(content.bounds.contains(recorderFrame))
    }

    func testW3_recordingAHotKeyStoresItShowsItAndReregisters() async throws {
        let delegate = try await launch()
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        let window = try XCTUnwrap(preferences.window)
        let recorder = preferences.hotKeyRecorder
        var reported: [HotKey] = []
        let forward = preferences.onHotKeyChange
        preferences.onHotKeyChange = { hotKey in
            reported.append(hotKey)
            forward?(hotKey)
        }

        // A click starts recording and takes focus.
        recorder.performClick(nil)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.title, HotKeyRecorder.recordingTitle)
        XCTAssertIdentical(window.firstResponder, recorder)

        try press(controlOptionSpace, characters: " ", in: window)

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.hotKey, controlOptionSpace)
        XCTAssertEqual(recorder.title, "⌃⌥Space")
        XCTAssertEqual(reported, [controlOptionSpace])
        XCTAssertEqual(preferences.hotKey, controlOptionSpace)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlOptionSpace, "stored (PR-1)")
        XCTAssertEqual(delegate.hotKey, controlOptionSpace)
        XCTAssertEqual(delegate.globalHotKey?.hotKey, controlOptionSpace, "re-registered")
        XCTAssertFalse(carbonAccepts(controlOptionSpace), "Carbon has the new one")
        XCTAssertTrue(carbonAccepts(controlCommandN), "and released the old one")

        // The new combination drives the same press path.
        var activations = 0
        delegate.activateApp = { activations += 1 }
        delegate.isAppActive = { false }
        try XCTUnwrap(delegate.globalHotKey).fire()
        XCTAssertEqual(activations, 1)

        // Recording the combination in use changes nothing and reports nothing.
        recorder.performClick(nil)
        try press(controlOptionSpace, characters: " ", in: window)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(reported, [controlOptionSpace])
        XCTAssertEqual(delegate.globalHotKey?.hotKey, controlOptionSpace)

        // Showing Preferences again shows the combination in use.
        preferences.close()
        delegate.showPreferences(nil)
        XCTAssertTrue(delegate.preferencesWindowController === preferences)
        XCTAssertEqual(recorder.title, "⌃⌥Space")
    }

    func testW3_recorderTakesKeyEquivalentsWhileRecording() async throws {
        let delegate = try await launch()
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        let window = try XCTUnwrap(preferences.window)
        let recorder = preferences.hotKeyRecorder

        // Not recording: Cmd-W is not the recorder's, so it reaches the window (which the
        // window would close; only the answer is checked here).
        let commandW = HotKey(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command])
        XCTAssertFalse(recorder.performKeyEquivalent(with: try keyDown(commandW, characters: "w", in: window)))

        // Recording: the same press is the new hotkey and goes no further.
        recorder.beginRecording()
        XCTAssertTrue(window.performKeyEquivalent(with: try keyDown(commandW, characters: "w", in: window)))
        XCTAssertTrue(window.isVisible, "not closed")
        XCTAssertEqual(recorder.hotKey, commandW)
        XCTAssertEqual(delegate.hotKey, commandW)
        XCTAssertFalse(recorder.isRecording)
    }

    func testW3_recorderIgnoresUnmodifiedKeysEscapeCancelsAndDeleteRestoresTheDefault() async throws {
        let delegate = try await launch()
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        let window = try XCTUnwrap(preferences.window)
        let recorder = preferences.hotKeyRecorder
        var reported: [HotKey] = []
        let forward = preferences.onHotKeyChange
        preferences.onHotKeyChange = { hotKey in
            reported.append(hotKey)
            forward?(hotKey)
        }
        let plainX = HotKey(keyCode: UInt16(kVK_ANSI_X), modifiers: [])
        let shiftX = HotKey(keyCode: UInt16(kVK_ANSI_X), modifiers: [.shift])
        let escape = HotKey(keyCode: UInt16(kVK_Escape), modifiers: [])
        let delete = HotKey(keyCode: UInt16(kVK_Delete), modifiers: [])

        // A key without Command, Control or Option keeps waiting.
        recorder.beginRecording()
        try press(plainX, characters: "x", in: window)
        XCTAssertTrue(recorder.isRecording)
        try press(shiftX, characters: "X", in: window)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.title, HotKeyRecorder.recordingTitle)

        // Escape cancels: nothing changed, stored or reported.
        try press(escape, characters: "\u{1B}", in: window)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.hotKey, controlCommandN)
        XCTAssertEqual(recorder.title, "⌃⌘N")
        XCTAssertEqual(reported, [])
        XCTAssertNil(UserDefaults.standard.object(forKey: HotKeyPreference.keyCodeDefaultsKey))
        XCTAssertEqual(delegate.globalHotKey?.hotKey, controlCommandN)

        // A second click while recording cancels too, as does losing focus.
        recorder.performClick(nil)
        XCTAssertTrue(recorder.isRecording)
        recorder.performClick(nil)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.title, "⌃⌘N")
        recorder.beginRecording()
        XCTAssertTrue(recorder.isRecording)
        window.makeFirstResponder(nil)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.title, "⌃⌘N")

        // Delete while recording restores the default.
        recorder.beginRecording()
        try press(commandShiftF5, characters: "\u{F708}", in: window)
        XCTAssertEqual(recorder.hotKey, commandShiftF5)
        XCTAssertEqual(delegate.globalHotKey?.hotKey, commandShiftF5)
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), commandShiftF5)
        recorder.beginRecording()
        try press(delete, characters: "\u{7F}", in: window)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.hotKey, controlCommandN)
        XCTAssertEqual(reported, [commandShiftF5, controlCommandN])
        XCTAssertEqual(HotKeyPreference.hotKey(from: .standard), controlCommandN)
        XCTAssertEqual(delegate.globalHotKey?.hotKey, controlCommandN)
        XCTAssertFalse(carbonAccepts(controlCommandN))
        XCTAssertTrue(carbonAccepts(commandShiftF5))
    }

    func testW3_setHotKeyBeforeLaunchOnlyMovesTheCombination() {
        let controller = makeMainWindowController()
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: root)
        delegate.setHotKey(controlOptionSpace)
        XCTAssertEqual(delegate.hotKey, controlOptionSpace)
        XCTAssertNil(delegate.globalHotKey)
        XCTAssertTrue(carbonAccepts(controlOptionSpace), "nothing registered before launch")
    }
}
