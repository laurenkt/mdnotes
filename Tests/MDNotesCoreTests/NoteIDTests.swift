import MDNotesCore
import XCTest

final class NoteIDTests: XCTestCase {
    func testTitleIsFilenameWithoutExtension() {
        XCTAssertEqual(NoteID(relativePath: "frantisek kupka.md").title, "frantisek kupka")
        XCTAssertEqual(NoteID(relativePath: "daily/2026/06-sunday.md").title, "06-sunday")
    }
}
