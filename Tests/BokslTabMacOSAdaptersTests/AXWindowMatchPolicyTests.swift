@testable import BokslTabMacOSAdapters
import XCTest

final class AXWindowMatchPolicyTests: XCTestCase {
    func testUniqueTitleMatchReturnsOnlyMatchIndex() {
        let index = AXWindowMatchPolicy.uniqueTitleMatchIndex(
            targetTitle: "Project",
            candidateTitles: ["Inbox", "Project", nil]
        )

        XCTAssertEqual(index, 1)
    }

    func testDuplicateTitleDoesNotClaimExactMatch() {
        let index = AXWindowMatchPolicy.uniqueTitleMatchIndex(
            targetTitle: "Project",
            candidateTitles: ["Project", "Project"]
        )

        XCTAssertNil(index)
    }

    func testBlankTitleDoesNotClaimExactMatch() {
        let index = AXWindowMatchPolicy.uniqueTitleMatchIndex(
            targetTitle: "  ",
            candidateTitles: ["Untitled"]
        )

        XCTAssertNil(index)
    }
}
