@testable import BokslTabMacOSAdapters
import BokslTabCore
import CoreGraphics
import XCTest

final class WindowTabPolicyTests: XCTestCase {
    private let groupFrame = CGRect(x: 0, y: 30, width: 2560, height: 1410)

    private func window(_ windowID: UInt32, title: String?, frame: CGRect? = nil) -> WindowSnapshot {
        WindowSnapshot(
            identity: WindowIdentity(windowID: windowID, ownerProcessIdentifier: 10, title: title),
            bounds: frame ?? groupFrame,
            ownerName: "IntelliJ IDEA"
        )
    }

    private func tabBar(of windowID: UInt32?, selected: Int, titles: [String] = ["Project A", "Project B", "Project C"]) -> AccessibilityWindowSnapshot {
        AccessibilityWindowSnapshot(
            windowID: windowID,
            title: nil,
            frame: groupFrame,
            tabs: titles.enumerated().map { index, title in
                AccessibilityTabSnapshot(index: index, title: title, isSelected: index == selected, source: .windowTabGroup)
            }
        )
    }

    /// The on-screen window is its own selected tab and keeps its window row. Tabs whose windows were
    /// never seen become tab rows of that window.
    func testOnScreenWindowKeepsItsRowAndUnseenTabsBecomeTabRows() throws {
        let onScreen = window(1211, title: "Custom title that names no project")
        let group = try XCTUnwrap(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1211, selected: 1),
            onScreenRows: [onScreen],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { _ in false }
        ))

        let rows = NativeTabMatcher(groups: [group]).unclaimedTabSnapshots()

        XCTAssertEqual(rows.map(\.identity.title), ["Project A", "Project C"])
        XCTAssertEqual(rows.map { $0.identity.tab?.index }, [0, 2])
        XCTAssertEqual(rows.map(\.identity.windowID), [1211, 1211])
        XCTAssertEqual(rows.map { $0.identity.tab?.parentWindowID }, [1211, 1211])
        XCTAssertEqual(rows.map { $0.identity.tab?.isSelected }, [false, false])
        XCTAssertEqual(rows[0].identity.tab?.parentTitle, "Custom title that names no project")
        XCTAssertEqual(rows[0].identity.tab?.parentFrame, WindowFrameIdentity(x: 0, y: 30, width: 2560, height: 1410))
    }

    /// A remembered project window takes the tab that names it, so it is listed once, under its number.
    func testRememberedWindowClaimsTheTabThatNamesIt() throws {
        let group = try XCTUnwrap(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1211, selected: 0),
            onScreenRows: [window(1211, title: "Project A – Main.kt")],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { _ in false }
        ))
        let matcher = NativeTabMatcher(groups: [group])

        XCTAssertTrue(matcher.claimTab(processIdentifier: 10, keys: ["project b"]))
        XCTAssertFalse(matcher.claimTab(processIdentifier: 10, keys: ["project b"]), "one tab stands for one window")
        XCTAssertFalse(matcher.claimTab(processIdentifier: 99, keys: ["project c"]), "another app's tab bar")
        XCTAssertFalse(matcher.claimTab(processIdentifier: 10, keys: ["closed project"]))

        XCTAssertEqual(matcher.unclaimedTabSnapshots().map(\.identity.title), ["Project C"])
    }

    /// Reported at 10:09:36 UTC: right after a project switch the details still described the previous
    /// project's window. That window is an unselected tab now; the window on screen took its place.
    func testTabBarReadBeforeATabSwitchBelongsToTheWindowNowOnScreen() throws {
        let group = try XCTUnwrap(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1241, selected: 2),
            onScreenRows: [window(1211, title: "Project A – Main.kt")],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { $0 == 1241 }
        ))
        let matcher = NativeTabMatcher(groups: [group])

        XCTAssertEqual(group.parent.identity.windowID, 1211)
        XCTAssertTrue(matcher.claimTab(processIdentifier: 10, keys: ["project c"]), "the window the details described")
        XCTAssertEqual(matcher.unclaimedTabSnapshots().map(\.identity.title), ["Project B"])
        XCTAssertEqual(matcher.unclaimedTabSnapshots().map { $0.identity.tab?.parentWindowID }, [1211])
    }

    func testOnScreenWindowIsRecognizedByItsRememberedTabTitle() throws {
        let group = try XCTUnwrap(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1241, selected: 2),
            onScreenRows: [window(1211, title: "~/work/a – Main.kt")],
            rememberedKeysByWindowID: [1211: ["project a"]],
            isOrderedOut: { $0 == 1241 }
        ))

        XCTAssertEqual(group.unclaimedTabs.map(\.title), ["Project B", "Project C"])
    }

    func testTabBarWithoutAWindowOfItsGroupOnScreenIsIgnored() {
        // The described window moved to another Space: it is neither on screen nor an unselected tab.
        XCTAssertNil(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1241, selected: 2),
            onScreenRows: [window(1211, title: "Project A – Main.kt")],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { _ in false }
        ))
        // An unselected tab now, but the only window on screen belongs to another group.
        XCTAssertNil(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1241, selected: 2),
            onScreenRows: [window(1211, title: "Project A – Main.kt", frame: CGRect(x: 2600, y: 30, width: 800, height: 600))],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { $0 == 1241 }
        ))
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

    func testSingleTabAndPlaceholderTitlesProduceNoTabRows() throws {
        let onScreen = window(1211, title: "IDE")

        XCTAssertNil(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1211, selected: 0, titles: ["Project A"]),
            onScreenRows: [onScreen],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { _ in false }
        ))

        let placeholders = try XCTUnwrap(NativeTabMatcher.Group(
            tabBar: tabBar(of: 1211, selected: 2, titles: ["창 101", "Window 102", "Project C"]),
            onScreenRows: [onScreen],
            rememberedKeysByWindowID: [:],
            isOrderedOut: { _ in false }
        ))
        XCTAssertTrue(NativeTabMatcher(groups: [placeholders]).unclaimedTabSnapshots().isEmpty)
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
