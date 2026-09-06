import AppKit
import Foundation
import MDNotesApp
import MDNotesCore
import XCTest

/// Headless smoke tests for the Preferences window's library folder (PR-1, L-1): the folder
/// is remembered in `UserDefaults` and read at launch, and choosing another one through the
/// window tears down the library controller and rebuilds it on the new root. The folder
/// chooser is replaced by a closure that answers at once, and driven through the real button.
@MainActor
final class PreferencesSmokeTests: XCTestCase {
    private var rootA: URL = FileManager.default.temporaryDirectory
    private var rootB: URL = FileManager.default.temporaryDirectory
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private let alpha = NoteID(relativePath: "Alpha.md")
    private let beta = NoteID(relativePath: "Beta.md")
    private let gamma = NoteID(relativePath: "Gamma.md")

    private let keys = [LibraryRootPreference.defaultsKey, MainView.listHeightDefaultsKey]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let stamp = UUID().uuidString
        rootA = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mdnotes-prefs-a-\(stamp)", isDirectory: true)
        rootB = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mdnotes-prefs-b-\(stamp)", isDirectory: true)
        try write(["Alpha.md": "alpha body", "Beta.md": "beta body"], to: rootA)
        try write(["Gamma.md": "gamma body"], to: rootB)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    /// Writes `notes` under `root`, one minute apart in the order given, so the empty query
    /// lists them last-written first (S-3).
    private func write(_ notes: KeyValuePairs<String, String>, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (i, note) in notes.enumerated() {
            let url = root.appendingPathComponent(note.key)
            try note.value.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.base.addingTimeInterval(Double(i) * 60)], ofItemAtPath: url.path)
        }
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

    /// A delegate launched against `rootA` through the real launch path, with the library
    /// ready and the list showing its notes. Whatever library the delegate ends up on is
    /// stopped at teardown.
    private func launch(clock: ManualAutosaveClock = ManualAutosaveClock()) async throws -> AppDelegate {
        let controller = makeMainWindowController(autosaveClock: clock)
        controller.window?.setContentSize(NSSize(width: 800, height: 600))
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: rootA)
        let box = DelegateBox(delegate)
        addTeardownBlock {
            await MainActor.run {
                box.delegate.libraryController?.stop()
                box.delegate.preferencesWindowController?.close()
                box.delegate.mainWindowController?.close()
            }
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let library = try XCTUnwrap(delegate.libraryController)
        await waitUntil("library A ready") { library.phase == .ready }
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha])
        return delegate
    }

    /// The Preferences window, shown, with its chooser answering `chosen`.
    private func showPreferences(of delegate: AppDelegate, choosing chosen: URL?) throws -> PreferencesWindowController
    {
        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        preferences.chooseFolder = { _, completion in completion(chosen) }
        return preferences
    }

    // MARK: - L-1: the folder is remembered across launches

    func testL1_defaultRootIsDocumentsMDnotesWhenNothingIsStored() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MDnotes", isDirectory: true)
        XCTAssertEqual(LibraryRootPreference.root(from: .standard).path, expected.path)
        XCTAssertEqual(AppDelegate().libraryRoot.path, expected.path)

        // A blank value is as good as none.
        UserDefaults.standard.set("  ", forKey: LibraryRootPreference.defaultsKey)
        XCTAssertEqual(LibraryRootPreference.root(from: .standard).path, expected.path)
    }

    func testL1_storedRootIsOpenedAtTheNextLaunch() {
        LibraryRootPreference.set(rootB, in: .standard)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: LibraryRootPreference.defaultsKey), rootB.standardizedFileURL.path)
        XCTAssertEqual(LibraryRootPreference.root(from: .standard), LibraryRootPreference.standardized(rootB))
        // A fresh delegate, as the next launch would make, opens the stored folder.
        XCTAssertEqual(AppDelegate().libraryRoot, LibraryRootPreference.standardized(rootB))
    }

    // MARK: - PR-1: the window

    func testPR1_preferencesWindowShowsTheLibraryFolderAndAChooseButton() async throws {
        let delegate = try await launch()
        XCTAssertNil(delegate.preferencesWindowController, "built on first use")

        delegate.showPreferences(nil)
        let preferences = try XCTUnwrap(delegate.preferencesWindowController)
        let window = try XCTUnwrap(preferences.window)
        XCTAssertEqual(window.title, "Preferences")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(preferences.libraryRoot, LibraryRootPreference.standardized(rootA))
        XCTAssertEqual(
            preferences.libraryFolderLabel.stringValue,
            (rootA.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath)
        XCTAssertEqual(preferences.chooseButton.title, "Choose…")
        XCTAssertTrue(preferences.chooseButton.isDescendant(of: try XCTUnwrap(window.contentView)))

        // Showing it again reuses the window.
        delegate.showPreferences(nil)
        XCTAssertTrue(delegate.preferencesWindowController === preferences)
    }

    func testPR1_cmdCommaShowsThePreferencesWindow() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let window = try XCTUnwrap(controller.window)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        XCTAssertTrue(controller.mainView.performKeyEquivalent(with: event))
        XCTAssertNotNil(delegate.preferencesWindowController)
        XCTAssertEqual(delegate.preferencesWindowController?.window?.isVisible, true)
    }

    // MARK: - PR-1, L-1: choosing a folder rebuilds the library controller

    func testPR1_choosingAFolderStoresItAndRebuildsTheLibraryOnTheNewRoot() async throws {
        let clock = ManualAutosaveClock()
        let delegate = try await launch(clock: clock)
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let oldLibrary = try XCTUnwrap(delegate.libraryController)
        let editor = controller.editorController

        // A note is open with an unsaved edit, and a query is typed.
        controller.mainView.searchField.stringValue = "a"
        controller.searchQueryDidChange()
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha])
        controller.listController.select(alpha)
        await waitUntil("alpha loaded") { editor.body != nil }
        XCTAssertEqual(controller.mainView.textView.string, "alpha body")
        let textView = controller.mainView.textView
        textView.insertText(" plus", replacementRange: NSRange(location: textView.string.utf16.count, length: 0))
        XCTAssertTrue(editor.hasUnsavedEdits)

        let preferences = try showPreferences(of: delegate, choosing: rootB)
        var reported: [URL] = []
        let forward = preferences.onLibraryRootChange
        preferences.onLibraryRootChange = { root in
            reported.append(root)
            forward?(root)
        }
        preferences.chooseButton.performClick(nil)

        // Remembered (L-1) and shown.
        let expectedB = LibraryRootPreference.standardized(rootB)
        XCTAssertEqual(reported, [expectedB])
        XCTAssertEqual(LibraryRootPreference.root(from: .standard), expectedB)
        XCTAssertEqual(preferences.libraryRoot, expectedB)
        XCTAssertEqual(
            preferences.libraryFolderLabel.stringValue, (expectedB.path as NSString).abbreviatingWithTildeInPath)

        // Torn down: the old controller is stopped and no longer the window's.
        XCTAssertEqual(oldLibrary.phase, .idle)
        XCTAssertEqual(oldLibrary.snapshot.count, 0)
        XCTAssertFalse(oldLibrary.isWatching)
        XCTAssertFalse(controller.library === oldLibrary)

        // Rebuilt: a new controller on the new root, attached and populating.
        let newLibrary = try XCTUnwrap(delegate.libraryController)
        XCTAssertFalse(newLibrary === oldLibrary)
        XCTAssertEqual(newLibrary.root, expectedB)
        XCTAssertEqual(delegate.libraryRoot, expectedB)
        XCTAssertTrue(controller.library === newLibrary)
        XCTAssertNotEqual(newLibrary.phase, .idle)

        // The editor let go of the old library's note, and the list of its rows, at once.
        XCTAssertNil(editor.noteID)
        XCTAssertEqual(controller.mainView.textView.string, "")
        XCTAssertFalse(controller.mainView.textView.isEditable)
        XCTAssertFalse(editor.hasUnsavedEdits)
        XCTAssertNil(controller.listController.selectedID)
        XCTAssertFalse(controller.listController.results.contains { $0.id == alpha || $0.id == beta })

        // The edit was written to the old root before it was left (E-4).
        await waitUntil("edit written") {
            (try? String(contentsOf: rootA.appendingPathComponent("Alpha.md"), encoding: .utf8)) == "alpha body plus"
        }

        // The new library fills the list, through the kept query.
        await waitUntil("library B ready") { newLibrary.phase == .ready }
        XCTAssertEqual(controller.query, "a")
        XCTAssertEqual(controller.listController.results.map(\.id), [gamma])
        XCTAssertNil(editor.noteID, "nothing is selected into the editor on the user's behalf")

        // The new library is live: selecting its note reads from the new root.
        controller.listController.select(gamma)
        await waitUntil("gamma loaded") { editor.body != nil }
        XCTAssertEqual(controller.mainView.textView.string, "gamma body")
    }

    func testPR1_cancellingTheChooserChangesNothing() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let library = try XCTUnwrap(delegate.libraryController)
        controller.listController.select(alpha)
        await waitUntil("alpha loaded") { controller.editorController.body != nil }

        let preferences = try showPreferences(of: delegate, choosing: nil)
        preferences.chooseButton.performClick(nil)

        XCTAssertTrue(delegate.libraryController === library)
        XCTAssertEqual(library.phase, .ready)
        XCTAssertNil(UserDefaults.standard.string(forKey: LibraryRootPreference.defaultsKey))
        XCTAssertEqual(delegate.libraryRoot, LibraryRootPreference.standardized(rootA))
        XCTAssertEqual(controller.editorController.noteID, alpha)
        XCTAssertEqual(controller.listController.results.map(\.id), [beta, alpha])
    }

    func testPR1_choosingTheCurrentFolderChangesNothing() async throws {
        let delegate = try await launch()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let library = try XCTUnwrap(delegate.libraryController)
        controller.listController.select(alpha)
        await waitUntil("alpha loaded") { controller.editorController.body != nil }

        // The same folder, spelled with a trailing slash and a `.` segment.
        let spelled = URL(fileURLWithPath: rootA.path + "/./", isDirectory: true)
        let preferences = try showPreferences(of: delegate, choosing: spelled)
        preferences.chooseButton.performClick(nil)

        XCTAssertTrue(delegate.libraryController === library)
        XCTAssertEqual(library.phase, .ready)
        XCTAssertNil(UserDefaults.standard.string(forKey: LibraryRootPreference.defaultsKey))
        XCTAssertEqual(controller.editorController.noteID, alpha)
    }

    func testPR1_openLibraryBeforeLaunchOnlyMovesTheRoot() {
        let controller = makeMainWindowController()
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: rootA)
        delegate.openLibrary(at: rootB)
        XCTAssertEqual(delegate.libraryRoot, LibraryRootPreference.standardized(rootB))
        XCTAssertNil(delegate.libraryController)
        XCTAssertNil(controller.library)
    }
}
