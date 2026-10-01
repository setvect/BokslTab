@testable import BokslTabMacOSAdapters
import BokslTabCore
import CoreGraphics
import XCTest

final class AccessibilityEventHistoryTests: XCTestCase {
    func testAccessibilityEventCachePolicyAddsHiddenTabbedWindowsButNotLiveDuplicate() {
        let live = WindowSnapshot(
            identity: WindowIdentity(
                windowID: 100,
                ownerProcessIdentifier: 42,
                title: "Project A"
            ),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            ownerName: "IntelliJ IDEA"
        )
        let entries = [
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: SyntheticWindowID.accessibilityEvent(
                    processIdentifier: 42,
                    title: "Project A",
                    frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                    index: 0
                ),
                title: "Project A",
                frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "IntelliJ IDEA",
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: SyntheticWindowID.accessibilityEvent(
                    processIdentifier: 42,
                    title: "Project B",
                    frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                    index: 1
                ),
                title: "Project B",
                frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "IntelliJ IDEA",
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        ]

        let snapshots = AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: [42],
            excluding: [live]
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].identity.title, "Project B")
        XCTAssertEqual(snapshots[0].identity.ownerProcessIdentifier, 42)
        XCTAssertEqual(snapshots[0].ownerName, "IntelliJ IDEA")
        XCTAssertGreaterThanOrEqual(snapshots[0].identity.windowID, 0x2000_0000)
        XCTAssertLessThan(snapshots[0].identity.windowID, 0x4000_0000)
    }

    func testAccessibilityEventCachePolicyRequiresLiveWindowForSameApp() {
        let entries = [
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: SyntheticWindowID.accessibilityEvent(
                    processIdentifier: 42,
                    title: "Finder Folder",
                    frame: CGRect(x: 100, y: 100, width: 900, height: 700),
                    index: 0
                ),
                title: "Finder Folder",
                frame: CGRect(x: 100, y: 100, width: 900, height: 700),
                ownerName: "Finder",
                source: "seed",
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        ]

        let snapshots = AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: [42],
            excluding: []
        )

        XCTAssertTrue(snapshots.isEmpty)
    }

    func testAccessibilityEventCachePolicySkipsAuxiliaryFrames() {
        let live = WindowSnapshot(
            identity: WindowIdentity(
                windowID: 100,
                ownerProcessIdentifier: 42,
                title: "Project A"
            ),
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            ownerName: "IntelliJ IDEA"
        )
        let entries = [
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: 1,
                title: "Project B",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                ownerName: "IntelliJ IDEA",
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: 2,
                title: "Push Commits",
                frame: CGRect(x: 415, y: 471, width: 800, height: 527),
                ownerName: "IntelliJ IDEA",
                source: "AXWindowCreated",
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        ]

        let snapshots = AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: [42],
            excluding: [live]
        )

        XCTAssertEqual(snapshots.map(\.identity.title), ["Project B"])
    }

    func testAccessibilityEventCachePolicyDeduplicatesSameProjectTitles() {
        let live = WindowSnapshot(
            identity: WindowIdentity(
                windowID: 100,
                ownerProcessIdentifier: 42,
                title: "BokslTab – Commit: MacOSWindowCatalogProvider.swift"
            ),
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 800),
            ownerName: "IntelliJ IDEA"
        )
        let entries = [
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: 1,
                title: "BokslTab – build-dev-app.sh",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                ownerName: "IntelliJ IDEA",
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: 2,
                title: "BokslDir – README.md",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                ownerName: "IntelliJ IDEA",
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: 3,
                title: "BokslDir – client.ts",
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                ownerName: "IntelliJ IDEA",
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        ]

        let snapshots = AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: [42],
            excluding: [live]
        )

        XCTAssertEqual(snapshots.map(\.identity.title), ["BokslDir – client.ts"])
    }

    func testAccessibilityEventWindowHistoryPolicyPreservesSameFrameOnly() {
        let current = AccessibilityEventWindowCacheEntry(
            processIdentifier: 42,
            windowID: 1,
            title: "Project A",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            source: "seed",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let sameFramePrevious = AccessibilityEventWindowCacheEntry(
            processIdentifier: 42,
            windowID: 2,
            title: "Project B",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            source: "AXMainWindowChanged",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let auxiliaryPrevious = AccessibilityEventWindowCacheEntry(
            processIdentifier: 42,
            windowID: 3,
            title: "Push Commits",
            frame: CGRect(x: 415, y: 471, width: 800, height: 527),
            source: "AXWindowCreated",
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertTrue(
            AccessibilityEventWindowHistoryPolicy.shouldPreserve(
                previous: sameFramePrevious,
                currentEntries: [current]
            )
        )
        XCTAssertFalse(
            AccessibilityEventWindowHistoryPolicy.shouldPreserve(
                previous: auxiliaryPrevious,
                currentEntries: [current]
            )
        )
        XCTAssertFalse(
            AccessibilityEventWindowHistoryPolicy.shouldPreserve(
                previous: sameFramePrevious,
                currentEntries: []
            )
        )
    }

    func testAccessibilityEventSyntheticWindowIDUsesStableProjectTitle() {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let firstFileID = SyntheticWindowID.accessibilityEvent(
            processIdentifier: 42,
            title: "BokslTab – Models.swift",
            frame: frame,
            index: 0
        )
        let secondFileID = SyntheticWindowID.accessibilityEvent(
            processIdentifier: 42,
            title: "BokslTab – SwitcherState.swift",
            frame: frame,
            index: 0
        )
        let otherProjectID = SyntheticWindowID.accessibilityEvent(
            processIdentifier: 42,
            title: "BokslDir – README.md",
            frame: frame,
            index: 0
        )

        XCTAssertEqual(firstFileID, secondFileID)
        XCTAssertNotEqual(firstFileID, otherProjectID)
    }

    func testAccessibilityEventWindowHistoryPolicyDoesNotPreserveSameProjectTitle() {
        let current = AccessibilityEventWindowCacheEntry(
            processIdentifier: 42,
            windowID: 1,
            title: "BokslTab – Commit: MacOSWindowCatalogProvider.swift",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            source: "seed",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let previous = AccessibilityEventWindowCacheEntry(
            processIdentifier: 42,
            windowID: 2,
            title: "BokslTab – build-dev-app.sh",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            source: "AXMainWindowChanged",
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertFalse(
            AccessibilityEventWindowHistoryPolicy.shouldPreserve(
                previous: previous,
                currentEntries: [current]
            )
        )
    }

    func testAccessibilityEventCachePolicySkipsUnsupportedPIDAndPlaceholderTitles() {
        let entries = [
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 42,
                windowID: 1,
                title: "창 123",
                frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            AccessibilityEventWindowCacheEntry(
                processIdentifier: 99,
                windowID: 2,
                title: "Project B",
                frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                source: "AXMainWindowChanged",
                updatedAt: Date(timeIntervalSince1970: 2)
            )
        ]

        let snapshots = AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: [42],
            excluding: []
        )

        XCTAssertTrue(snapshots.isEmpty)
    }

}
