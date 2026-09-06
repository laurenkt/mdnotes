import Foundation
import MDNotesCore
import XCTest

final class WordSplitterTests: XCTestCase {
    private func words(_ text: String) -> [String] {
        WordSplitter.words(of: text).map(String.init)
    }

    // MARK: S-2 splitting on whitespace

    func testS2_splitsOnAnyWhitespace() {
        XCTAssertEqual(words("alpha beta"), ["alpha", "beta"])
        XCTAssertEqual(words("alpha\tbeta\ngamma\r\ndelta"), ["alpha", "beta", "gamma", "delta"])
        XCTAssertEqual(words("alpha\u{00A0}beta\u{3000}gamma"), ["alpha", "beta", "gamma"])
    }

    func testS2_runsOfWhitespaceAndEdgesProduceNoEmptyWords() {
        XCTAssertEqual(words("  alpha\t\tbeta \n"), ["alpha", "beta"])
        XCTAssertEqual(words("alpha   beta"), ["alpha", "beta"])
        XCTAssertEqual(words("\n\nalpha\n\n"), ["alpha"])
    }

    func testS2_emptyOrBlankTextHasNoWords() {
        XCTAssertEqual(words(""), [])
        XCTAssertEqual(words(" "), [])
        XCTAssertEqual(words("   \t\n"), [])
        XCTAssertEqual(WordSplitter.foldedWords(of: "   \t\n"), [])
    }

    func testS2_wordsKeepTheirOrderAndDuplicates() {
        XCTAssertEqual(words("beta alpha beta"), ["beta", "alpha", "beta"])
        XCTAssertEqual(words("pattern the operator"), ["pattern", "the", "operator"])
    }

    func testS2_thereIsNoTokenisationBeyondWhitespace() {
        // Punctuation and symbols are part of the word they touch (ADR-0003: substring, not token).
        XCTAssertEqual(words("c++ foo-bar (baz) it's"), ["c++", "foo-bar", "(baz)", "it's"])
        XCTAssertEqual(words("daily/2026/06-sunday"), ["daily/2026/06-sunday"])
        XCTAssertEqual(words("[[Meeting Notes]]"), ["[[Meeting", "Notes]]"])
        XCTAssertEqual(words("masterplan"), ["masterplan"])
    }

    func testS2_wordsArePreservedAsTyped() {
        // `words(of:)` is the raw split; only `foldedWords(of:)` applies the case folding.
        XCTAssertEqual(words("Meeting NOTES"), ["Meeting", "NOTES"])
    }

    func testS2_foldedWordsApplyTheSharedCaseFolding() {
        XCTAssertEqual(WordSplitter.foldedWords(of: "Meeting NOTES FRANTIŠEK"), ["meeting", "notes", "františek"])
        for text in ["Meeting NOTES", "  #Swift\tUI ", "", "x"] {
            XCTAssertEqual(
                WordSplitter.foldedWords(of: text),
                WordSplitter.words(of: text).map(CaseFolding.fold),
                "foldedWords and words.map(fold) disagree for \(text)")
        }
    }

    // MARK: S-4 tags are ordinary words

    func testS4_hashTagIsAnOrdinaryWord() {
        XCTAssertEqual(words("#swift"), ["#swift"])
        XCTAssertEqual(words("learning #swift today"), ["learning", "#swift", "today"])
        XCTAssertEqual(words("#dev/swift #UI"), ["#dev/swift", "#UI"])
        XCTAssertEqual(WordSplitter.foldedWords(of: "#Dev/Swift #UI"), ["#dev/swift", "#ui"])
    }
}
