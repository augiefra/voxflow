import XCTest
@testable import VoxFlowCore

final class DictationHistoryTests: XCTestCase {
    func testKeepsTheFiveMostRecentNewestFirst() {
        var history = DictationHistory()
        for i in 1...7 { history.add("dictée \(i)") }
        XCTAssertEqual(history.items, ["dictée 7", "dictée 6", "dictée 5", "dictée 4", "dictée 3"])
    }

    func testRepeatedTextMovesToTopWithoutDuplicate() {
        var history = DictationHistory()
        history.add("a"); history.add("b"); history.add("a")
        XCTAssertEqual(history.items, ["a", "b"])
    }

    func testIgnoresBlankText() {
        var history = DictationHistory()
        history.add("  \n")
        XCTAssertTrue(history.items.isEmpty)
    }

    func testMenuTitleIsOneShortLine() {
        XCTAssertEqual(DictationHistory.menuTitle("Bonjour\nClaude"), "Bonjour Claude")
        let long = DictationHistory.menuTitle(String(repeating: "x", count: 100), limit: 60)
        XCTAssertEqual(long.count, 60)
        XCTAssertTrue(long.hasSuffix("…"))
    }
}
