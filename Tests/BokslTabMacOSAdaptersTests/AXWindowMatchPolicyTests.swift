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
        let index = WindowFrameMatchPolicy.bestFrameMatchIndex(
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            candidateFrames: [
                CGRect(x: 0, y: 0, width: 400, height: 300),
                CGRect(x: 102, y: 101, width: 400, height: 300)
            ]
        )

        XCTAssertEqual(index, 1)
    }

    func testFrameMatchRejectsEqualDistanceTie() {
        let index = WindowFrameMatchPolicy.bestFrameMatchIndex(
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            candidateFrames: [
                CGRect(x: 99, y: 100, width: 400, height: 300),
                CGRect(x: 101, y: 100, width: 400, height: 300)
            ]
        )

        XCTAssertNil(index)
    }

    func testSizeMatchHandlesDesktopRevealMovedOrigins() {
        let index = WindowFrameMatchPolicy.bestSizeMatchIndex(
            targetFrame: CGRect(x: -1600, y: 100, width: 820, height: 600),
            candidateFrames: [
                CGRect(x: 100, y: 100, width: 500, height: 400),
                CGRect(x: 200, y: 120, width: 822, height: 602)
            ]
        )

        XCTAssertEqual(index, 1)
    }

    func testSizeMatchRejectsEqualSizeTie() {
        let index = WindowFrameMatchPolicy.bestSizeMatchIndex(
            targetFrame: CGRect(x: -1600, y: 100, width: 820, height: 600),
            candidateFrames: [
                CGRect(x: 100, y: 100, width: 820, height: 600),
                CGRect(x: 200, y: 120, width: 820, height: 600)
            ]
        )

        XCTAssertNil(index)
    }

    func testUniqueTitleFallbackAssignsRealTitlesToUntitledWindowsDeterministically() {
        let assignments = AXTitleFallbackPolicy.assignUniqueTitles(
            untitledWindowIDs: [613, 77],
            availableTitles: [
                "oh-my-codex - YouTube - Brave",
                "[#again_playlist] 이소라의 프로포즈 레전드 Playlist | KBS 방송 - Brave"
            ]
        )

        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments[77], "[#again_playlist] 이소라의 프로포즈 레전드 Playlist | KBS 방송 - Brave")
        XCTAssertEqual(assignments[613], "oh-my-codex - YouTube - Brave")
    }

    func testUniqueTitleFallbackRejectsDuplicateOrCountMismatch() {
        XCTAssertTrue(
            AXTitleFallbackPolicy.assignUniqueTitles(
                untitledWindowIDs: [1, 2],
                availableTitles: ["Same", "Same"]
            ).isEmpty
        )
        XCTAssertTrue(
            AXTitleFallbackPolicy.assignUniqueTitles(
                untitledWindowIDs: [1, 2],
                availableTitles: ["Only one"]
            ).isEmpty
        )
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
