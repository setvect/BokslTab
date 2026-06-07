@testable import BokslTabMacOSAdapters
import BokslTabCore
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

    func testAccessibilityMatchRejectsSingleRemainingCandidateWithDifferentGeometry() {
        let fullscreenToolbarSurface = WindowSnapshot(
            identity: WindowIdentity(windowID: 12860, ownerProcessIdentifier: 2187, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 143),
            ownerName: "Brave Browser"
        )
        let actualFullscreenWindow = AccessibilityWindowSnapshot(
            title: "클로드 코워크 세팅 - YouTube - Brave",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )

        let matchIndex = AccessibilityWindowMatchPolicy.bestMatchIndex(
            for: fullscreenToolbarSurface,
            candidates: [actualFullscreenWindow],
            candidateIndices: [0]
        )

        XCTAssertNil(matchIndex)
    }

    func testAccessibilityMatchAcceptsSingleRemainingCandidateWithMatchingGeometry() {
        let fullscreenSurface = WindowSnapshot(
            identity: WindowIdentity(windowID: 11723, ownerProcessIdentifier: 2187, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            ownerName: "Brave Browser"
        )
        let actualFullscreenWindow = AccessibilityWindowSnapshot(
            title: "클로드 코워크 세팅 - YouTube - Brave",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )

        let matchIndex = AccessibilityWindowMatchPolicy.bestMatchIndex(
            for: fullscreenSurface,
            candidates: [actualFullscreenWindow],
            candidateIndices: [0]
        )

        XCTAssertEqual(matchIndex, 0)
    }

    func testUniqueTitleFallbackAssignsRealTitlesToUntitledWindowsDeterministically() {
        let assignments = AXTitleFallbackPolicy.assignUniqueTitles(
            candidateWindowIDs: [613, 77],
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
                candidateWindowIDs: [1, 2],
                availableTitles: ["Same", "Same"]
            ).isEmpty
        )
        XCTAssertTrue(
            AXTitleFallbackPolicy.assignUniqueTitles(
                candidateWindowIDs: [1, 2],
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

    func testBestTitleUsesAccessibilityWhenCoreGraphicsTitleIsOnlyOwnerName() {
        XCTAssertEqual(
            WindowTitleSelectionPolicy.bestTitle(
                coreGraphicsTitle: "Code",
                accessibilityTitle: "README.md — BokslCodex",
                ownerName: "Code"
            ),
            "README.md — BokslCodex"
        )
    }

    func testGenericOwnerNameTitleNeedsAccessibilityFallback() {
        let snapshot = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "Electron"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            ownerName: "Electron"
        )

        XCTAssertTrue(WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(snapshot))
    }

    func testSpecificWindowTitleDoesNotNeedAccessibilityFallback() {
        let snapshot = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "SwitcherPanelView.swift — BokslTab"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            ownerName: "Code"
        )

        XCTAssertFalse(WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(snapshot))
    }

    func testDuplicateFilterSuppressesUntitledWindowOverlappingTitledWindowForSameProcess() {
        let titled = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "I Put Grok Build to the Test - YouTube - Brave"),
            bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )
        let fullscreenSurface = WindowSnapshot(
            identity: WindowIdentity(windowID: 101, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )

        let filtered = WindowCatalogDuplicateFilterPolicy.filter([fullscreenSurface, titled])

        XCTAssertEqual(filtered.map(\.identity.windowID), [100])
    }

    func testDuplicateFilterSuppressesThinFullscreenAuxiliaryWindow() {
        let titledFullscreenWindow = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "I Put Grok Build to the Test - YouTube - Brave"),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let untitledFullscreenHelper = WindowSnapshot(
            identity: WindowIdentity(windowID: 101, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: -41, width: 2560, height: 41)
        )

        let filtered = WindowCatalogDuplicateFilterPolicy.filter([untitledFullscreenHelper, titledFullscreenWindow])

        XCTAssertEqual(filtered.map(\.identity.windowID), [100])
    }

    func testDuplicateFilterSuppressesShortFullscreenToolbarOverlay() {
        let titledFullscreenWindow = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "클로드 코워크 세팅 - YouTube - Brave"),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let untitledToolbarOverlay = WindowSnapshot(
            identity: WindowIdentity(windowID: 101, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 143)
        )

        let filtered = WindowCatalogDuplicateFilterPolicy.filter([untitledToolbarOverlay, titledFullscreenWindow])

        XCTAssertEqual(filtered.map(\.identity.windowID), [100])
    }

    func testDuplicateFilterKeepsUntitledWindowWithDifferentGeometry() {
        let titled = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "Project"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let separateUntitledWindow = WindowSnapshot(
            identity: WindowIdentity(windowID: 101, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 1100, y: 0, width: 500, height: 400)
        )

        let filtered = WindowCatalogDuplicateFilterPolicy.filter([separateUntitledWindow, titled])

        XCTAssertEqual(filtered.map(\.identity.windowID), [101, 100])
    }

    func testDuplicateFilterKeepsUntitledWindowForDifferentProcess() {
        let titled = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 42, title: "Project"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let otherProcessUntitledWindow = WindowSnapshot(
            identity: WindowIdentity(windowID: 101, ownerProcessIdentifier: 43, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700)
        )

        let filtered = WindowCatalogDuplicateFilterPolicy.filter([otherProcessUntitledWindow, titled])

        XCTAssertEqual(filtered.map(\.identity.windowID), [101, 100])
    }

    func testDuplicateFilterKeepsThinUntitledWindowWithoutSameProcessTitle() {
        let untitledFullscreenHelper = WindowSnapshot(
            identity: WindowIdentity(windowID: 101, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: -41, width: 2560, height: 41)
        )

        let filtered = WindowCatalogDuplicateFilterPolicy.filter([untitledFullscreenHelper])

        XCTAssertEqual(filtered.map(\.identity.windowID), [101])
    }

    func testAXOnlyPolicyBuildsTitledWindowsForAppsWithoutCGWindows() {
        let app = AppIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.brave.Browser",
            localizedName: "Brave Browser",
            processName: "Brave Browser"
        )

        let snapshots = AXOnlyWindowCatalogPolicy.snapshotsForAppsWithoutCGWindows(
            apps: [app],
            axSnapshotsByPID: [
                42: [
                    AccessibilityWindowSnapshot(
                        title: "I Put Grok Build to the Test - YouTube - Brave",
                        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
                    )
                ]
            ]
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].identity.ownerProcessIdentifier, 42)
        XCTAssertEqual(snapshots[0].identity.title, "I Put Grok Build to the Test - YouTube - Brave")
        XCTAssertGreaterThanOrEqual(snapshots[0].identity.windowID, 0x8000_0000)
    }

    func testAXOnlyPolicySkipsBlankOrSmallWindows() {
        let app = AppIdentity(processIdentifier: 42, localizedName: "Brave Browser")

        let snapshots = AXOnlyWindowCatalogPolicy.snapshotsForAppsWithoutCGWindows(
            apps: [app],
            axSnapshotsByPID: [
                42: [
                    AccessibilityWindowSnapshot(
                        title: "   ",
                        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
                    ),
                    AccessibilityWindowSnapshot(
                        title: "Too small",
                        frame: CGRect(x: 0, y: 0, width: 39, height: 1440)
                    )
                ]
            ]
        )

        XCTAssertTrue(snapshots.isEmpty)
    }

    func testWindowTitleCacheReturnsLastKnownTitleWhenAppHasNoLiveWindow() {
        let cache = WindowTitleCache()
        let app = AppIdentity(processIdentifier: 42, localizedName: "Brave Browser")
        cache.record([
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: 11723,
                    ownerProcessIdentifier: 42,
                    title: "클로드 코워크 세팅 - YouTube - Brave"
                ),
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                ownerName: "Brave Browser"
            )
        ])

        let snapshots = cache.snapshots(for: [app], excluding: [])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].identity.ownerProcessIdentifier, 42)
        XCTAssertEqual(snapshots[0].identity.title, "클로드 코워크 세팅 - YouTube - Brave")
        XCTAssertGreaterThanOrEqual(snapshots[0].identity.windowID, 0x4000_0000)
        XCTAssertLessThan(snapshots[0].identity.windowID, 0x8000_0000)
    }

    func testWindowTitleCacheSkipsShortAuxiliarySurfaces() {
        let cache = WindowTitleCache()
        cache.record([
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: 12860,
                    ownerProcessIdentifier: 42,
                    title: "클로드 코워크 세팅 - YouTube - Brave"
                ),
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 143),
                ownerName: "Brave Browser"
            )
        ])

        let snapshots = cache.snapshots(
            for: [AppIdentity(processIdentifier: 42, localizedName: "Brave Browser")],
            excluding: []
        )

        XCTAssertTrue(snapshots.isEmpty)
    }

    func testWindowTitleCacheAppliesKnownTitleToLargestWeakLiveWindow() {
        let cache = WindowTitleCache()
        cache.record([
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: 11723,
                    ownerProcessIdentifier: 42,
                    title: "클로드 코워크 세팅 - YouTube - Brave"
                ),
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                ownerName: "Brave Browser"
            )
        ])
        let toolbarSurface = WindowSnapshot(
            identity: WindowIdentity(windowID: 12860, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 143),
            ownerName: "Brave Browser"
        )
        let fullscreenSurface = WindowSnapshot(
            identity: WindowIdentity(windowID: 11723, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            ownerName: "Brave Browser"
        )

        let snapshots = cache.applyCachedTitles(to: [toolbarSurface, fullscreenSurface])

        XCTAssertNil(snapshots[0].identity.title)
        XCTAssertEqual(snapshots[1].identity.title, "클로드 코워크 세팅 - YouTube - Brave")
    }

    func testWindowTitleCacheSkipsMismatchedOwnerNameForReusedPID() {
        let cache = WindowTitleCache()
        cache.record([
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: 11723,
                    ownerProcessIdentifier: 42,
                    title: "클로드 코워크 세팅 - YouTube - Brave"
                ),
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                ownerName: "Brave Browser"
            )
        ])

        let snapshots = cache.snapshots(
            for: [AppIdentity(processIdentifier: 42, localizedName: "Code")],
            excluding: []
        )

        XCTAssertTrue(snapshots.isEmpty)
    }

    func testWindowTitleCacheEvictsLeastRecentlyUsedEntryWhenBounded() {
        func snapshot(processIdentifier: Int32, title: String) -> WindowSnapshot {
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: UInt32(processIdentifier),
                    ownerProcessIdentifier: processIdentifier,
                    title: title
                ),
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "App \(processIdentifier)"
            )
        }

        let cache = WindowTitleCache(maxEntries: 2)
        cache.record([
            snapshot(processIdentifier: 1, title: "One"),
            snapshot(processIdentifier: 2, title: "Two")
        ])
        _ = cache.snapshots(
            for: [AppIdentity(processIdentifier: 1, localizedName: "App 1")],
            excluding: []
        )

        cache.record([snapshot(processIdentifier: 3, title: "Three")])

        let snapshots = cache.snapshots(
            for: [
                AppIdentity(processIdentifier: 1, localizedName: "App 1"),
                AppIdentity(processIdentifier: 2, localizedName: "App 2"),
                AppIdentity(processIdentifier: 3, localizedName: "App 3")
            ],
            excluding: []
        )

        XCTAssertEqual(snapshots.map(\.identity.ownerProcessIdentifier), [1, 3])
        XCTAssertEqual(snapshots.map(\.identity.title), ["One", "Three"])
    }
}
