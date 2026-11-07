import BokslTabCore
@testable import BokslTabMacOSAdapters
import CoreGraphics
import XCTest

final class MacOSMRUOrderingProviderTests: XCTestCase {
    func testProviderBuildsFrontToBackContextForMatchingWindows() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "App")
        let current = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 300, ownerProcessIdentifier: 10, title: "Current")))
        let previous = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 200, ownerProcessIdentifier: 10, title: "Previous")))
        let unrelatedInfo = windowInfo(windowID: 999, pid: 99)
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(
                infoList: [
                    windowInfo(windowID: 300, pid: 10),
                    unrelatedInfo,
                    windowInfo(windowID: 200, pid: 10)
                ]
            )
        )

        let context = provider.orderingContext(for: .activeAppWindows, items: [previous, current])

        XCTAssertEqual(context.orderedItemIDs, [current.id, previous.id])
        XCTAssertEqual(context.currentItemID, current.id)
        XCTAssertEqual(context.sourceDescription, "cg-window-list-front-to-back")
        XCTAssertNil(context.fallbackReason)
    }

    func testProviderProjectsWindowOrderToAppFallbackRows() {
        let terminal = AppIdentity(processIdentifier: 10, localizedName: "Terminal")
        let notes = AppIdentity(processIdentifier: 20, localizedName: "Notes")
        let current = SwitcherItem(app: terminal, kind: .window(WindowIdentity(windowID: 300, ownerProcessIdentifier: 10, title: "Current")))
        let previousAppFallback = SwitcherItem(app: notes, kind: .app)
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(
                infoList: [
                    windowInfo(windowID: 300, pid: 10),
                    windowInfo(windowID: 400, pid: 20)
                ]
            )
        )

        let context = provider.orderingContext(for: .allAppsAndWindows, items: [previousAppFallback, current])
        let ordered = SwitcherMRUOrderer.order(items: [previousAppFallback, current], context: context)

        XCTAssertEqual(context.orderedItemIDs, [current.id, previousAppFallback.id])
        XCTAssertEqual(context.currentItemID, current.id)
        XCTAssertEqual(ordered.map(\.id), [current.id, previousAppFallback.id])
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
    }

    func testProviderPrefersWindowStackingOverStaleActivationHistory() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "App")
        let current = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 300, ownerProcessIdentifier: 10, title: "Current")))
        let previous = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 100, ownerProcessIdentifier: 10, title: "Previous")))
        let older = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 200, ownerProcessIdentifier: 10, title: "Older")))
        // A click inside the same app reorders windows without any app activation, so history still
        // lists the older window first.
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(
                infoList: [
                    windowInfo(windowID: 300, pid: 10),
                    windowInfo(windowID: 100, pid: 10),
                    windowInfo(windowID: 200, pid: 10)
                ]
            ),
            initialRecentItemIDs: [older.id, previous.id]
        )

        let context = provider.orderingContext(for: .activeAppWindows, items: [older, previous, current])
        let ordered = SwitcherMRUOrderer.order(items: [older, previous, current], context: context)

        XCTAssertEqual(context.orderedItemIDs, [current.id, previous.id, older.id])
        XCTAssertEqual(context.currentItemID, current.id)
        XCTAssertEqual(context.sourceDescription, "cg-window-list-front-to-back")
        XCTAssertEqual(ordered.map(\.title), ["Current", "Previous", "Older"])
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
    }

    /// Reported at 21:14: Code#97 was third in the window stacking but listed seventh,
    /// below every Chrome window that the activation history happened to remember.
    func testProviderListsWindowsMissingFromHistoryAtTheirStackingPosition() {
        let claude = AppIdentity(processIdentifier: 2766, localizedName: "Claude")
        let code = AppIdentity(processIdentifier: 661, localizedName: "Code")
        let chrome = AppIdentity(processIdentifier: 645, localizedName: "Chrome")
        let frontToBack: [(app: AppIdentity, windowID: UInt32)] = [
            (claude, 240), (code, 95), (code, 97), (chrome, 689), (chrome, 156), (chrome, 220)
        ]
        let stacking = frontToBack.map { row in
            SwitcherItem(app: row.app, kind: .window(WindowIdentity(
                windowID: row.windowID,
                ownerProcessIdentifier: row.app.processIdentifier,
                title: "\(row.windowID)"
            )))
        }
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(
                infoList: frontToBack.map { windowInfo(windowID: $0.windowID, pid: $0.app.processIdentifier) }
            ),
            initialRecentItemIDs: [stacking[0], stacking[1], stacking[3], stacking[5], stacking[4]].map(\.id)
        )
        let items = Array(stacking.reversed())

        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)
        let ordered = SwitcherMRUOrderer.order(items: items, context: context)

        XCTAssertEqual(ordered.map(\.id), stacking.map(\.id))
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
    }

    func testProviderPlacesInactiveTabFromHistoryAheadOfOlderOnScreenWindow() {
        let ide = AppIdentity(processIdentifier: 10, localizedName: "IDE")
        let browser = AppIdentity(processIdentifier: 20, localizedName: "Browser")
        let previousTab = SwitcherItem(
            app: ide,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: "Project A",
                tab: WindowTabIdentity(parentWindowID: 300, index: 0, title: "Project A", isSelected: false)
            ))
        )
        let currentTab = SwitcherItem(
            app: ide,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: "Project B",
                tab: WindowTabIdentity(parentWindowID: 300, index: 1, title: "Project B", isSelected: true)
            ))
        )
        let browserWindow = SwitcherItem(app: browser, kind: .window(WindowIdentity(windowID: 400, ownerProcessIdentifier: 20, title: "Docs")))
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: [windowInfo(windowID: 300, pid: 10), windowInfo(windowID: 400, pid: 20)]),
            initialRecentItemIDs: [previousTab.id, browserWindow.id]
        )

        let items = [browserWindow, previousTab, currentTab]
        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)
        let ordered = SwitcherMRUOrderer.order(items: items, context: context)

        XCTAssertEqual(ordered.map(\.id), [currentTab.id, previousTab.id, browserWindow.id])
        XCTAssertEqual(context.sourceDescription, "cg-window-list-front-to-back+activation-history")
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
    }

    func testMergerPlacesOffScreenRowAboveTheTopmostOlderOnScreenRow() {
        let result = MRUOrderMerger.merge(
            frontToBackItemIDs: ["B", "C", "D"],
            historyItemIDs: ["B", "X", "D", "C", "Y"]
        )

        XCTAssertEqual(result.orderedItemIDs, ["B", "X", "C", "D", "Y"])
        XCTAssertEqual(result.historyOnlyItemIDs, ["X", "Y"])
    }

    func testMergerTreatsOnScreenRowsMissingFromHistoryAsOlder() {
        let result = MRUOrderMerger.merge(
            frontToBackItemIDs: ["desktop", "chat", "editor"],
            historyItemIDs: ["desktop", "fullScreen", "editor"]
        )

        XCTAssertEqual(result.orderedItemIDs, ["desktop", "fullScreen", "chat", "editor"])
    }

    /// Back on the desktop after a full-screen window: it is off screen, yet it was used right before
    /// the current window, so it is the default selection.
    func testProviderSelectsFullScreenWindowUsedBeforeTheCurrentDesktopWindow() {
        let chrome = AppIdentity(processIdentifier: 645, localizedName: "Chrome")
        let kakao = AppIdentity(processIdentifier: 667, localizedName: "KakaoTalk")
        let desktop = SwitcherItem(app: chrome, kind: .window(WindowIdentity(windowID: 151, ownerProcessIdentifier: 645, title: "Docs")))
        let fullScreen = SwitcherItem(app: chrome, kind: .window(WindowIdentity(windowID: 689, ownerProcessIdentifier: 645, title: "Video")))
        let chat = SwitcherItem(app: kakao, kind: .window(WindowIdentity(windowID: 78, ownerProcessIdentifier: 667, title: "Chat")))
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(
                infoList: [windowInfo(windowID: 151, pid: 645), windowInfo(windowID: 78, pid: 667)]
            ),
            initialRecentItemIDs: [fullScreen.id]
        )
        let items = [chat, desktop, fullScreen]

        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)
        let ordered = SwitcherMRUOrderer.order(items: items, context: context)

        XCTAssertEqual(ordered.map(\.id), [desktop.id, fullScreen.id, chat.id])
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
    }

    /// Reported at 10:26 UTC: right after leaving the full-screen window 2914 for 689, 2914 was last
    /// in the list instead of selected. In its Space the topmost window was the toolbar Chrome keeps
    /// above a full-screen window. That toolbar is not a row, so 2914 never entered the history.
    func testProviderRemembersFullScreenWindowUnderAnUnlistedToolbarWindow() {
        let chrome = AppIdentity(processIdentifier: 645, localizedName: "Chrome")
        let claude = AppIdentity(processIdentifier: 2766, localizedName: "Claude")
        let newVideo = SwitcherItem(app: chrome, kind: .window(WindowIdentity(windowID: 2914, ownerProcessIdentifier: 645, title: "New video")))
        let video = SwitcherItem(app: chrome, kind: .window(WindowIdentity(windowID: 689, ownerProcessIdentifier: 645, title: "Video")))
        let chat = SwitcherItem(app: claude, kind: .window(WindowIdentity(windowID: 240, ownerProcessIdentifier: 2766, title: "Chat")))
        let lister = MutableCGWindowInfoLister()
        let provider = MacOSMRUOrderingProvider(windowInfoLister: lister, initialRecentItemIDs: [chat.id, video.id])
        let items = [chat, newVideo, video]

        lister.infoList = [windowInfo(windowID: 2917, pid: 645), windowInfo(windowID: 2914, pid: 645)]
        XCTAssertEqual(provider.orderingContext(for: .allAppsAndWindows, items: items).currentItemID, newVideo.id)

        // The user picks 689, which is on the desktop with Claude.
        provider.recordActivatedItem(video)
        lister.infoList = [windowInfo(windowID: 689, pid: 645), windowInfo(windowID: 240, pid: 2766)]
        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)
        let ordered = SwitcherMRUOrderer.order(items: items, context: context)

        XCTAssertEqual(ordered.map(\.id), [video.id, newVideo.id, chat.id])
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
    }


    func testProviderMapsStableTitleHistoryAfterAccessibilityEventTitleChanges() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "IntelliJ IDEA")
        let currentTitle = "BokslTab – Models.swift"
        let current = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: currentTitle,
                source: .accessibilityEvent
            ))
        )
        let previousTitleAlias = SwitcherItem.stableTitleAliasID(
            ownerProcessIdentifier: 10,
            title: "BokslTab – SwitcherMRUOrdering.swift"
        )!
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: []),
            initialRecentItemIDs: [previousTitleAlias]
        )

        let context = provider.orderingContext(for: .activeAppWindows, items: [current])

        XCTAssertEqual(context.orderedItemIDs, [current.id])
        XCTAssertEqual(context.currentItemID, current.id)
        XCTAssertNil(context.fallbackReason)
    }

    func testProviderFallsBackWhenWindowInfoIsUnavailable() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "App")
        let item = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 300, ownerProcessIdentifier: 10, title: "Current")))
        let provider = MacOSMRUOrderingProvider(windowInfoLister: FakeCGWindowInfoLister(infoList: nil))

        let context = provider.orderingContext(for: .allAppsAndWindows, items: [item])

        XCTAssertTrue(context.isFallback)
        XCTAssertEqual(context.fallbackReason, "cg-window-list-unavailable")
    }

    func testProviderFallsBackWhenNoWindowsMatchItems() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "App")
        let item = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 300, ownerProcessIdentifier: 10, title: "Current")))
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: [windowInfo(windowID: 999, pid: 99)])
        )

        let context = provider.orderingContext(for: .allAppsAndWindows, items: [item])

        XCTAssertTrue(context.isFallback)
        XCTAssertEqual(context.fallbackReason, "no-matching-front-to-back-windows")
    }


    func testProviderMapsParentWindowToSelectedTabOnly() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "IDE")
        let firstTab = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: "Project A",
                tab: WindowTabIdentity(parentWindowID: 300, index: 0, title: "Project A", isSelected: false)
            ))
        )
        let selectedTab = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: "Project B",
                tab: WindowTabIdentity(parentWindowID: 300, index: 1, title: "Project B", isSelected: true)
            ))
        )
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: [windowInfo(windowID: 300, pid: 10)])
        )

        let context = provider.orderingContext(for: .activeAppWindows, items: [firstTab, selectedTab])

        XCTAssertEqual(context.orderedItemIDs, [selectedTab.id])
        XCTAssertEqual(context.currentItemID, selectedTab.id)
    }

    func testProviderDoesNotMapParentWindowToArbitraryTabWithoutSelectedFlag() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "IDE")
        let firstTab = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: "Project A",
                tab: WindowTabIdentity(parentWindowID: 300, index: 0, title: "Project A", isSelected: false)
            ))
        )
        let secondTab = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: "Project B",
                tab: WindowTabIdentity(parentWindowID: 300, index: 1, title: "Project B", isSelected: false)
            ))
        )
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: [windowInfo(windowID: 300, pid: 10)])
        )

        let context = provider.orderingContext(for: .activeAppWindows, items: [firstTab, secondTab])

        XCTAssertTrue(context.isFallback)
        XCTAssertEqual(context.fallbackReason, "no-matching-front-to-back-windows")
    }

    func testProviderMapsTabHistoryAfterParentWindowIDChanges() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "IntelliJ IDEA")
        let previousTab = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 400,
                ownerProcessIdentifier: 10,
                title: "Project A – Main.swift",
                tab: WindowTabIdentity(
                    parentWindowID: 400,
                    index: 0,
                    title: "Project A – Main.swift"
                )
            ))
        )
        let currentTab = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 400,
                ownerProcessIdentifier: 10,
                title: "Project B",
                tab: WindowTabIdentity(
                    parentWindowID: 400,
                    index: 1,
                    title: "Project B",
                    isSelected: true
                )
            ))
        )
        let previousTitleAlias = SwitcherItem.stableTitleAliasID(
            ownerProcessIdentifier: 10,
            title: "Project A – Older.swift"
        )!
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: [windowInfo(windowID: 400, pid: 10)]),
            initialRecentItemIDs: [previousTitleAlias]
        )

        let context = provider.orderingContext(
            for: .allAppsAndWindows,
            items: [previousTab, currentTab]
        )
        let ordered = SwitcherMRUOrderer.order(items: [previousTab, currentTab], context: context)

        XCTAssertEqual(context.orderedItemIDs, [currentTab.id, previousTab.id])
        XCTAssertEqual(context.currentItemID, currentTab.id)
        XCTAssertEqual(ordered.map(\.id), [currentTab.id, previousTab.id])
    }


    private func windowInfo(windowID: UInt32, pid: Int32) -> [String: Any] {
        [
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 400, height: 300)
                .dictionaryRepresentation
        ]
    }
}

private struct FakeCGWindowInfoLister: CGWindowInfoListing {
    let infoList: [[String: Any]]?

    func windowInfoList() -> [[String: Any]]? {
        infoList
    }
}

private final class MutableCGWindowInfoLister: CGWindowInfoListing {
    var infoList: [[String: Any]]?

    func windowInfoList() -> [[String: Any]]? {
        infoList
    }
}
