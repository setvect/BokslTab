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

    func testTabExpandedDiagnosticDescriptionRedactsTabTitle() {
        let parent = WindowSnapshot(
            identity: WindowIdentity(windowID: 100, ownerProcessIdentifier: 10, title: "IDE"),
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            ownerName: "IntelliJ IDEA"
        )
        let result = TabExpandedWindowCatalogPolicy.expand(
            snapshot: parent,
            tabs: [
                AccessibilityTabSnapshot(index: 0, title: "Secret Project A", isSelected: true, source: .windowTabs),
                AccessibilityTabSnapshot(index: 1, title: "Secret Project B", isSelected: false, source: .windowTabs)
            ]
        )

        let diagnostic = result.snapshots[0].diagnosticDescription

        XCTAssertFalse(diagnostic.contains("Secret Project A"))
        XCTAssertTrue(diagnostic.contains("title=<redacted>"))
        XCTAssertTrue(diagnostic.contains("tabTitleKnown=true"))
        XCTAssertTrue(diagnostic.contains("tabTitleLength=16"))
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
