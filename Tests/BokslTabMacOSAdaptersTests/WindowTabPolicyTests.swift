@testable import BokslTabMacOSAdapters
import BokslTabCore
import CoreGraphics
import XCTest

final class WindowTabPolicyTests: XCTestCase {
    func testTabExpansionCreatesSeparateWindowItemsForUsableTabs() {
        let parent = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 10, title: "IDE"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            ownerName: "IntelliJ IDEA"
        )
        let result = TabExpandedWindowCatalogPolicy.expand(
            snapshot: parent,
            tabs: [
                AccessibilityTabSnapshot(index: 0, title: "Project A", isSelected: false, source: .windowTabs),
                AccessibilityTabSnapshot(index: 1, title: "Project B", isSelected: true, source: .windowTabs)
            ]
        )

        XCTAssertTrue(result.didExpand)
        XCTAssertEqual(result.snapshots.map(\.identity.title), ["Project A", "Project B"])
        XCTAssertEqual(result.snapshots.map { $0.identity.tab?.index }, [0, 1])
        XCTAssertEqual(result.snapshots[1].identity.tab?.isSelected, true)
        XCTAssertEqual(result.snapshots[1].identity.tab?.parentTitle, "IDE")
        XCTAssertEqual(result.snapshots.map(\.identity.windowID), [100, 100])

        let framed = TabExpandedWindowCatalogPolicy.expand(
            snapshot: parent,
            tabs: [
                AccessibilityTabSnapshot(index: 0, title: "Project A", isSelected: false, source: .windowTabs),
                AccessibilityTabSnapshot(index: 1, title: "Project B", isSelected: true, source: .windowTabs)
            ],
            parentFrame: WindowFrameIdentity(x: 10, y: 20, width: 900, height: 700)
        )
        XCTAssertEqual(framed.snapshots[0].identity.tab?.parentFrame, WindowFrameIdentity(x: 10, y: 20, width: 900, height: 700))
    }

    func testNativeWindowTabGroupPolicyUsesDirectAXTabButtonsOnly() {
        struct Node {
            let role: String
            let subrole: String?
            let children: [String]
        }
        let nodes = [
            "root": Node(role: "AXGroup", subrole: nil, children: ["nested-tab-group"]),
            "nested-tab-group": Node(role: "AXTabGroup", subrole: nil, children: ["editor-tab"]),
            "editor-tab": Node(role: "AXRadioButton", subrole: "AXTabButton", children: []),
            "native-tab-group": Node(role: "AXTabGroup", subrole: nil, children: ["project-a", "close", "project-b"]),
            "project-a": Node(role: "AXRadioButton", subrole: "AXTabButton", children: []),
            "project-b": Node(role: "AXRadioButton", subrole: "AXTabButton", children: []),
            "close": Node(role: "AXButton", subrole: nil, children: []),
            "radio-group": Node(role: "AXTabGroup", subrole: nil, children: ["generic-radio"]),
            "generic-radio": Node(role: "AXRadioButton", subrole: nil, children: [])
        ]

        let result = NativeWindowTabGroupPolicy.tabElements(
            windowChildren: ["root", "native-tab-group", "radio-group"],
            children: { nodes[$0]?.children ?? [] },
            role: { nodes[$0]?.role },
            subrole: { nodes[$0]?.subrole }
        )

        XCTAssertEqual(result, ["project-a", "project-b"])
    }

    func testTabExpansionFallsBackForSingleOrPlaceholderTabs() {
        let parent = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 10, title: "IDE"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            ownerName: "IntelliJ IDEA"
        )

        let single = TabExpandedWindowCatalogPolicy.expand(
            snapshot: parent,
            tabs: [AccessibilityTabSnapshot(index: 0, title: "Project A", isSelected: true, source: .windowTabs)]
        )
        XCTAssertFalse(single.didExpand)
        XCTAssertEqual(single.fallbackReason, "single-tab")

        let placeholders = TabExpandedWindowCatalogPolicy.expand(
            snapshot: parent,
            tabs: [
                AccessibilityTabSnapshot(index: 0, title: "창 101", isSelected: false, source: .windowTabs),
                AccessibilityTabSnapshot(index: 1, title: "Window 102", isSelected: true, source: .windowTabs)
            ]
        )
        XCTAssertFalse(placeholders.didExpand)
        XCTAssertEqual(placeholders.fallbackReason, "placeholder-title")
    }

    func testAXTabMatchPolicyRequiresTitleEvidence() {
        let element = AXUIElementCreateApplication(0)
        let candidates = [
            AXTabElementSnapshot(index: 0, title: "Project A", isSelected: false, element: element),
            AXTabElementSnapshot(index: 1, title: "Project B", isSelected: true, element: element)
        ]

        XCTAssertEqual(
            AXTabMatchPolicy.bestMatchIndex(
                target: WindowTabIdentity(parentWindowID: 100, index: 1, title: "Project B"),
                candidates: candidates
            ),
            1
        )
        XCTAssertEqual(
            AXTabMatchPolicy.bestMatchIndex(
                target: WindowTabIdentity(parentWindowID: 100, index: 0, title: "Project B"),
                candidates: candidates
            ),
            1
        )
        XCTAssertNil(
            AXTabMatchPolicy.bestMatchIndex(
                target: WindowTabIdentity(parentWindowID: 100, index: 0, title: "Renamed/Stale"),
                candidates: candidates
            )
        )
        XCTAssertNil(
            AXTabMatchPolicy.bestMatchIndex(
                target: WindowTabIdentity(parentWindowID: 100, index: 9, title: "Project B"),
                candidates: candidates
            )
        )
    }

    func testAXTabMatchPolicyRejectsDuplicateTitleWithoutIndexMatch() {
        let element = AXUIElementCreateApplication(0)
        let candidates = [
            AXTabElementSnapshot(index: 0, title: "Project A", isSelected: false, element: element),
            AXTabElementSnapshot(index: 1, title: "Project A", isSelected: true, element: element)
        ]

        XCTAssertEqual(
            AXTabMatchPolicy.bestMatchIndex(
                target: WindowTabIdentity(parentWindowID: 100, index: 1, title: "Project A"),
                candidates: candidates
            ),
            1
        )
        XCTAssertNil(
            AXTabMatchPolicy.bestMatchIndex(
                target: WindowTabIdentity(parentWindowID: 100, index: 2, title: "Project A"),
                candidates: candidates
            )
        )
    }

    func testAXParentWindowMatchPolicyPrefersFrameBeforeTitle() {
        let target = WindowTabIdentity(
            parentWindowID: 100,
            parentTitle: "IDE",
            parentFrame: WindowFrameIdentity(x: 100, y: 100, width: 900, height: 700),
            index: 0,
            title: "Project A"
        )

        let result = AXParentWindowMatchPolicy.candidateIndices(
            target: target,
            candidateTitles: ["IDE", "IDE"],
            candidateFrames: [
                CGRect(x: 400, y: 400, width: 900, height: 700),
                CGRect(x: 102, y: 101, width: 900, height: 700)
            ]
        )

        XCTAssertEqual(result.indices, [1])
        XCTAssertEqual(result.strategy, "frame")
    }

    func testAXParentWindowMatchPolicyFallsBackToUniqueTitleWhenFrameDoesNotMatch() {
        let target = WindowTabIdentity(
            parentWindowID: 100,
            parentTitle: "IDE",
            parentFrame: WindowFrameIdentity(x: 100, y: 100, width: 900, height: 700),
            index: 0,
            title: "Project A"
        )

        let result = AXParentWindowMatchPolicy.candidateIndices(
            target: target,
            candidateTitles: ["Other", "IDE"],
            candidateFrames: [
                CGRect(x: 400, y: 400, width: 850, height: 650),
                CGRect(x: 600, y: 600, width: 800, height: 600)
            ]
        )

        XCTAssertEqual(result.indices, [1])
        XCTAssertEqual(result.strategy, "title")
    }

    func testBrowserOwnerNamesAreNotEligibleForTabExpansion() {
        XCTAssertFalse(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "Brave Browser"))
        XCTAssertFalse(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "Google Chrome"))
        XCTAssertFalse(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "Safari"))
        XCTAssertFalse(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "Vivaldi"))
        XCTAssertFalse(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "Arcade Utility"))
        XCTAssertTrue(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "IntelliJ IDEA"))
        XCTAssertTrue(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: "Finder"))
        XCTAssertFalse(AppTabExpansionEligibilityPolicy.canExpandTabs(ownerName: nil))
    }

    func testAppTabExpansionEligibilityUsesBundleIdentifiers() {
        XCTAssertTrue(
            AppTabExpansionEligibilityPolicy.decision(
                for: AppTabExpansionAppDescriptor(bundleIdentifier: "com.jetbrains.intellij")
            ).canExpandTabs
        )
        XCTAssertTrue(
            AppTabExpansionEligibilityPolicy.decision(
                for: AppTabExpansionAppDescriptor(bundleIdentifier: "com.apple.finder")
            ).canExpandTabs
        )
        XCTAssertFalse(
            AppTabExpansionEligibilityPolicy.decision(
                for: AppTabExpansionAppDescriptor(bundleIdentifier: "com.vivaldi.Vivaldi")
            ).canExpandTabs
        )
    }

}
