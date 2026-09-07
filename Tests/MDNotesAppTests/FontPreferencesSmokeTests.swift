import AppKit
import MDNotesApp
import XCTest

/// Headless smoke tests for the editor font in the Preferences window (PR-1, E-8): a family
/// pop-up and a size field with a stepper, read from `UserDefaults` when the window is shown,
/// written back when the user chooses, and followed by the editor at once. The controls are
/// driven through their real actions, as a click or Enter would send them.
@MainActor
final class FontPreferencesSmokeTests: XCTestCase {
    private let keys = [
        EditorFontPreference.familyDefaultsKey, EditorFontPreference.sizeDefaultsKey, MainView.listHeightDefaultsKey,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await super.tearDown()
    }

    private var systemMonospaced13: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

    private var storedFamily: String? { UserDefaults.standard.string(forKey: EditorFontPreference.familyDefaultsKey) }
    private var storedSize: Double? {
        (UserDefaults.standard.object(forKey: EditorFontPreference.sizeDefaultsKey) as? NSNumber)?.doubleValue
    }

    // MARK: - Fixture

    /// Counts on the main actor from a notification block.
    @MainActor
    private final class Counter {
        var count = 0
    }

    /// Main-actor box so a delegate can ride inside a `@Sendable` teardown block.
    @MainActor
    private final class DelegateBox {
        let delegate: AppDelegate
        init(_ delegate: AppDelegate) { self.delegate = delegate }
    }

    /// A delegate with a main window, not launched: the font path needs no library. Its
    /// windows are closed at teardown.
    private func makeDelegate() -> AppDelegate {
        let controller = makeMainWindowController()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mdnotes-font-prefs-\(UUID().uuidString)", isDirectory: true)
        let delegate = AppDelegate(mainWindowController: controller, libraryRoot: root)
        let box = DelegateBox(delegate)
        addTeardownBlock {
            await MainActor.run {
                box.delegate.preferencesWindowController?.close()
                box.delegate.mainWindowController?.close()
            }
        }
        return delegate
    }

    /// The Preferences window, shown.
    private func showPreferences(of delegate: AppDelegate) throws -> PreferencesWindowController {
        delegate.showPreferences(nil)
        return try XCTUnwrap(delegate.preferencesWindowController)
    }

    /// Chooses `title` in the family pop-up as a click on the item would.
    private func choose(_ title: String, in preferences: PreferencesWindowController) {
        let popUp = preferences.fontFamilyPopUp
        popUp.selectItem(withTitle: title)
        XCTAssertEqual(popUp.titleOfSelectedItem, title, "the pop-up lists \(title)")
        XCTAssertTrue(popUp.sendAction(popUp.action, to: popUp.target))
    }

    /// Types `text` into the size field and presses Enter.
    private func enter(_ text: String, in preferences: PreferencesWindowController) {
        let field = preferences.fontSizeField
        field.stringValue = text
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
    }

    /// Steps the size to `value` as a click on the stepper would.
    private func step(to value: Double, in preferences: PreferencesWindowController) {
        let stepper = preferences.fontSizeStepper
        stepper.doubleValue = value
        XCTAssertTrue(stepper.sendAction(stepper.action, to: stepper.target))
    }

    // MARK: - PR-1: the font row

    func testPR1_preferencesWindowShowsTheEditorFontRow() throws {
        let delegate = makeDelegate()
        let preferences = try showPreferences(of: delegate)
        let content = try XCTUnwrap(preferences.window?.contentView)
        let popUp = preferences.fontFamilyPopUp
        let field = preferences.fontSizeField
        let stepper = preferences.fontSizeStepper
        XCTAssertTrue(popUp.isDescendant(of: content))
        XCTAssertTrue(field.isDescendant(of: content))
        XCTAssertTrue(stepper.isDescendant(of: content))
        XCTAssertTrue(preferences.chooseButton.isDescendant(of: content), "the folder row is still there")
        XCTAssertTrue(preferences.hotKeyRecorder.isDescendant(of: content), "and the hotkey row")

        // The default is shown: the system monospaced family at 13 pt (E-8).
        XCTAssertNil(preferences.editorFontFamily)
        XCTAssertEqual(preferences.editorFontSize, 13)
        XCTAssertEqual(popUp.titleOfSelectedItem, PreferencesWindowController.systemMonospacedTitle)
        XCTAssertEqual(field.stringValue, "13")
        XCTAssertEqual(stepper.doubleValue, 13)
        XCTAssertEqual(stepper.minValue, Double(EditorFontPreference.minimumSize))
        XCTAssertEqual(stepper.maxValue, Double(EditorFontPreference.maximumSize))
        XCTAssertEqual(stepper.increment, 1)

        // The pop-up lists the default first, then the installed families, sorted.
        XCTAssertEqual(popUp.itemTitles.first, PreferencesWindowController.systemMonospacedTitle)
        let families = EditorFontPreference.availableFamilies
        XCTAssertTrue(families.contains("Menlo"))
        XCTAssertTrue(families.contains("Helvetica"))
        XCTAssertFalse(families.contains { $0.hasPrefix(".") }, "private faces are left out")
        XCTAssertEqual(
            families, families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertEqual(Array(popUp.itemTitles.dropFirst(2)), families, "after the default and a separator")
        XCTAssertTrue(popUp.item(at: 1)?.isSeparatorItem == true)

        // Laid out between the folder row and the hotkey row, within the window.
        preferences.window?.layoutIfNeeded()
        let popUpFrame = popUp.convert(popUp.bounds, to: content)
        let fieldFrame = field.convert(field.bounds, to: content)
        let stepperFrame = stepper.convert(stepper.bounds, to: content)
        let chooseFrame = preferences.chooseButton.convert(preferences.chooseButton.bounds, to: content)
        let recorderFrame = preferences.hotKeyRecorder.convert(preferences.hotKeyRecorder.bounds, to: content)
        XCTAssertGreaterThan(popUpFrame.width, 0)
        XCTAssertGreaterThan(fieldFrame.width, 0)
        XCTAssertLessThan(popUpFrame.maxY, chooseFrame.minY, "below the folder row (flipped: y grows upward)")
        XCTAssertGreaterThan(popUpFrame.minY, recorderFrame.maxY, "above the hotkey row")
        XCTAssertLessThan(popUpFrame.maxX, fieldFrame.minX, "the size follows the family")
        XCTAssertLessThan(fieldFrame.maxX, stepperFrame.minX, "and the stepper the size")
        XCTAssertTrue(content.bounds.contains(popUpFrame))
        XCTAssertTrue(content.bounds.contains(fieldFrame))
        XCTAssertTrue(content.bounds.contains(stepperFrame))
        XCTAssertTrue(content.bounds.contains(recorderFrame))
    }

    // MARK: - E-8: choosing a family

    func testE8_choosingAFamilyStoresItAndRestylesTheEditor() throws {
        let delegate = makeDelegate()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let textView = controller.mainView.textView
        XCTAssertEqual(textView.font, systemMonospaced13)
        let preferences = try showPreferences(of: delegate)

        choose("Menlo", in: preferences)

        XCTAssertEqual(storedFamily, "Menlo", "stored (PR-1)")
        XCTAssertNil(storedSize, "the size preference is not touched")
        XCTAssertEqual(preferences.editorFontFamily, "Menlo")
        XCTAssertEqual(preferences.fontFamilyPopUp.titleOfSelectedItem, "Menlo")
        let font = try XCTUnwrap(textView.font)
        XCTAssertEqual(font.familyName, "Menlo", "the editor follows at once")
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertEqual(controller.editorController.styler.baseFont, font, "and so does the styling's base")
        XCTAssertEqual(textView.typingAttributes[.font] as? NSFont, font)

        // Another family replaces it.
        choose("Helvetica", in: preferences)
        XCTAssertEqual(storedFamily, "Helvetica")
        XCTAssertEqual(try XCTUnwrap(textView.font).familyName, "Helvetica")
    }

    func testE8_choosingSystemMonospacedRemovesTheFamilyPreference() throws {
        let delegate = makeDelegate()
        let textView = try XCTUnwrap(delegate.mainWindowController).mainView.textView
        let preferences = try showPreferences(of: delegate)
        choose("Menlo", in: preferences)
        XCTAssertEqual(storedFamily, "Menlo")

        choose(PreferencesWindowController.systemMonospacedTitle, in: preferences)

        XCTAssertNil(storedFamily, "removed, not stored as a name")
        XCTAssertNil(preferences.editorFontFamily)
        XCTAssertEqual(
            preferences.fontFamilyPopUp.titleOfSelectedItem, PreferencesWindowController.systemMonospacedTitle)
        XCTAssertEqual(textView.font, systemMonospaced13)
    }

    // MARK: - E-8: entering a size

    func testE8_enteringASizeStoresItAndRestylesTheEditor() throws {
        let delegate = makeDelegate()
        let controller = try XCTUnwrap(delegate.mainWindowController)
        let textView = controller.mainView.textView
        let preferences = try showPreferences(of: delegate)

        enter("16", in: preferences)

        XCTAssertEqual(storedSize, 16, "stored (PR-1)")
        XCTAssertNil(storedFamily, "the family preference is not touched")
        XCTAssertEqual(preferences.editorFontSize, 16)
        XCTAssertEqual(preferences.fontSizeField.stringValue, "16")
        XCTAssertEqual(preferences.fontSizeStepper.doubleValue, 16, "the stepper follows the field")
        XCTAssertEqual(textView.font, NSFont.monospacedSystemFont(ofSize: 16, weight: .regular))
        XCTAssertEqual(controller.editorController.styler.baseFont, textView.font)

        // A fraction, with spaces around it, is a size too.
        enter(" 11.5 ", in: preferences)
        XCTAssertEqual(storedSize, 11.5)
        XCTAssertEqual(preferences.fontSizeField.stringValue, "11.5")
        XCTAssertEqual(try XCTUnwrap(textView.font).pointSize, 11.5)

        // The size goes with whatever family is chosen.
        choose("Menlo", in: preferences)
        enter("14", in: preferences)
        let font = try XCTUnwrap(textView.font)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 14)
    }

    func testE8_steppingTheSizeStoresItAndRestylesTheEditor() throws {
        let delegate = makeDelegate()
        let textView = try XCTUnwrap(delegate.mainWindowController).mainView.textView
        let preferences = try showPreferences(of: delegate)

        step(to: 14, in: preferences)

        XCTAssertEqual(storedSize, 14)
        XCTAssertEqual(preferences.editorFontSize, 14)
        XCTAssertEqual(preferences.fontSizeField.stringValue, "14", "the field follows the stepper")
        XCTAssertEqual(try XCTUnwrap(textView.font).pointSize, 14)

        step(to: 13, in: preferences)
        XCTAssertEqual(storedSize, 13)
        XCTAssertEqual(preferences.fontSizeField.stringValue, "13")
        XCTAssertEqual(textView.font, systemMonospaced13)
    }

    func testE8_anUnusableSizeIsNotStoredAndTheFieldRevertsToTheSizeInUse() throws {
        let delegate = makeDelegate()
        let textView = try XCTUnwrap(delegate.mainWindowController).mainView.textView
        let preferences = try showPreferences(of: delegate)
        enter("15", in: preferences)
        XCTAssertEqual(storedSize, 15)

        for text in ["large", "", "0", "-3", "5", "73", "1e9", "nan", "inf"] {
            enter(text, in: preferences)
            XCTAssertEqual(storedSize, 15, "\(text) is not a size")
            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.fontSizeField.stringValue, "15", "reverted after \(text)")
            XCTAssertEqual(preferences.fontSizeStepper.doubleValue, 15)
            XCTAssertEqual(try XCTUnwrap(textView.font).pointSize, 15)
        }

        // The bounds themselves are sizes.
        enter("6", in: preferences)
        XCTAssertEqual(storedSize, 6)
        enter("72", in: preferences)
        XCTAssertEqual(storedSize, 72)
        XCTAssertEqual(try XCTUnwrap(textView.font).pointSize, 72)
    }

    func testE8_choosingTheValuesInUseChangesNothing() throws {
        let delegate = makeDelegate()
        let textView = try XCTUnwrap(delegate.mainWindowController).mainView.textView
        let preferences = try showPreferences(of: delegate)

        choose(PreferencesWindowController.systemMonospacedTitle, in: preferences)
        enter("13", in: preferences)
        step(to: 13, in: preferences)

        XCTAssertNil(storedFamily, "nothing stored")
        XCTAssertNil(storedSize)
        XCTAssertEqual(textView.font, systemMonospaced13)

        // The same holds for a chosen family and size.
        choose("Menlo", in: preferences)
        enter("15", in: preferences)
        let changes = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { _ in MainActor.assumeIsolated { changes.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        choose("Menlo", in: preferences)
        enter("15", in: preferences)
        enter("15.0", in: preferences)
        step(to: 15, in: preferences)
        XCTAssertEqual(changes.count, 0, "the defaults were not written")
        XCTAssertEqual(storedFamily, "Menlo")
        XCTAssertEqual(storedSize, 15)
        XCTAssertEqual(preferences.fontSizeField.stringValue, "15")
    }

    // MARK: - E-8, PR-1: the window shows the stored preference

    func testE8_storedPreferenceIsShownWhenTheWindowIsShown() throws {
        UserDefaults.standard.set("Menlo", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)
        let delegate = makeDelegate()
        let preferences = try showPreferences(of: delegate)
        XCTAssertEqual(preferences.editorFontFamily, "Menlo")
        XCTAssertEqual(preferences.editorFontSize, 15)
        XCTAssertEqual(preferences.fontFamilyPopUp.titleOfSelectedItem, "Menlo")
        XCTAssertEqual(preferences.fontSizeField.stringValue, "15")
        XCTAssertEqual(preferences.fontSizeStepper.doubleValue, 15)

        // A preference changed while the window was closed is shown when it opens again.
        preferences.close()
        UserDefaults.standard.set("Helvetica", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set(11.5, forKey: EditorFontPreference.sizeDefaultsKey)
        delegate.showPreferences(nil)
        XCTAssertTrue(delegate.preferencesWindowController === preferences)
        XCTAssertEqual(preferences.fontFamilyPopUp.titleOfSelectedItem, "Helvetica")
        XCTAssertEqual(preferences.fontSizeField.stringValue, "11.5")

        // A stored family that is not installed shows as the default, which is what the
        // editor uses (E-8); an unusable size shows as 13.
        preferences.close()
        UserDefaults.standard.set("No Such Family 4f2c", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set("large", forKey: EditorFontPreference.sizeDefaultsKey)
        delegate.showPreferences(nil)
        XCTAssertEqual(preferences.editorFontFamily, "No Such Family 4f2c", "the stored name is kept")
        XCTAssertEqual(
            preferences.fontFamilyPopUp.titleOfSelectedItem, PreferencesWindowController.systemMonospacedTitle)
        XCTAssertEqual(preferences.fontSizeField.stringValue, "13")
        XCTAssertEqual(preferences.editorFontSize, 13)
        XCTAssertEqual(try XCTUnwrap(delegate.mainWindowController).mainView.textView.font, systemMonospaced13)

        // Choosing the default from there removes the unusable name.
        choose(PreferencesWindowController.systemMonospacedTitle, in: preferences)
        XCTAssertNil(storedFamily)
    }
}
