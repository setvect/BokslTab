@testable import BokslTabMacOSAdapters
import CoreGraphics
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

    func testFrameMatchChoosesClosestCandidateRatherThanListOrder() {
        let index = WindowFrameMatchPolicy.bestMatchIndex(
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            candidateFrames: [
                CGRect(x: 0, y: 0, width: 400, height: 300),
                CGRect(x: 102, y: 101, width: 400, height: 300)
            ]
        )

        XCTAssertEqual(index, 1)
    }

    func testFrameMatchRejectsEqualDistanceTie() {
        let index = WindowFrameMatchPolicy.bestMatchIndex(
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            candidateFrames: [
                CGRect(x: 99, y: 100, width: 400, height: 300),
                CGRect(x: 101, y: 100, width: 400, height: 300)
            ]
        )

        XCTAssertNil(index)
    }

    func testBestTitleUsesAccessibilityWhenItAddsContext() {
        XCTAssertEqual(
            WindowTitleSelectionPolicy.bestTitle(
                coreGraphicsTitle: "Google Chrome",
                accessibilityTitle: "BokslTab 요구사항 - Google Chrome"
            ),
            "BokslTab 요구사항 - Google Chrome"
        )
    }

    func testBestTitleFallsBackToCoreGraphicsWhenAccessibilityIsBlank() {
        XCTAssertEqual(
            WindowTitleSelectionPolicy.bestTitle(coreGraphicsTitle: "Project.swift", accessibilityTitle: "   "),
            "Project.swift"
        )
    }
}
