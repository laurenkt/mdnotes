import AppKit
import MDNotesApp
import XCTest

/// Headless smoke tests for the editor font preference (E-8): read from `UserDefaults` when
/// the window is built, applied again when the defaults change.
@MainActor
final class EditorFontSmokeTests: XCTestCase {
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

    func testE8_defaultIsTheSystemMonospacedFontAt13pt() {
        XCTAssertEqual(EditorFontPreference.defaultSize, 13)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), systemMonospaced13)

        let controller = makeMainWindowController()
        let textView = controller.mainView.textView
        XCTAssertEqual(textView.font, systemMonospaced13)
        XCTAssertEqual(textView.typingAttributes[.font] as? NSFont, systemMonospaced13, "typed text gets it too")
    }

    func testE8_familyAndSizeAreReadFromUserDefaults() throws {
        UserDefaults.standard.set("Menlo", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set(15, forKey: EditorFontPreference.sizeDefaultsKey)

        let controller = makeMainWindowController()
        let font = try XCTUnwrap(controller.mainView.textView.font)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 15)
    }

    func testE8_familyAndSizeFallBackIndependently() throws {
        // Size alone: the system monospaced family at that size.
        UserDefaults.standard.set(11.5, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(
            EditorFontPreference.font(from: .standard), NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))

        // Family alone: that family at 13 pt.
        UserDefaults.standard.removeObject(forKey: EditorFontPreference.sizeDefaultsKey)
        UserDefaults.standard.set("Helvetica", forKey: EditorFontPreference.familyDefaultsKey)
        let helvetica = EditorFontPreference.font(from: .standard)
        XCTAssertEqual(helvetica.familyName, "Helvetica")
        XCTAssertEqual(helvetica.pointSize, 13)
    }

    func testE8_unusableValuesFallBackToTheDefault() {
        UserDefaults.standard.set("No Such Family 4f2c", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set(-3, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), systemMonospaced13)

        UserDefaults.standard.set("  ", forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.set("large", forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), systemMonospaced13)

        UserDefaults.standard.set(0, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(EditorFontPreference.font(from: .standard), systemMonospaced13)

        // An unusable family does not cost the size preference.
        UserDefaults.standard.set(17, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(
            EditorFontPreference.font(from: .standard), NSFont.monospacedSystemFont(ofSize: 17, weight: .regular))
    }

    func testE8_changingThePreferenceRestylesTheEditor() throws {
        let controller = makeMainWindowController()
        let textView = controller.mainView.textView
        XCTAssertEqual(textView.font, systemMonospaced13)

        UserDefaults.standard.set("Menlo", forKey: EditorFontPreference.familyDefaultsKey)
        XCTAssertEqual(try XCTUnwrap(textView.font).familyName, "Menlo")
        XCTAssertEqual(try XCTUnwrap(textView.font).pointSize, 13)

        UserDefaults.standard.set(16, forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(try XCTUnwrap(textView.font).familyName, "Menlo")
        XCTAssertEqual(try XCTUnwrap(textView.font).pointSize, 16)

        // Removing the preference goes back to the default.
        UserDefaults.standard.removeObject(forKey: EditorFontPreference.familyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: EditorFontPreference.sizeDefaultsKey)
        XCTAssertEqual(textView.font, systemMonospaced13)
    }
}
