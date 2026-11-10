import AppKit
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

    func testMergerPlacesOffScreenRowBelowTheLowestNewerOnScreenRow() {
        let result = MRUOrderMerger.merge(
            frontToBackItemIDs: ["B", "C", "D"],
            recordedItemIDs: ["B", "X", "D", "C", "Y"]
        )

        XCTAssertEqual(result.orderedItemIDs, ["B", "X", "C", "D", "Y"])
        XCTAssertEqual(result.offScreenItemIDs, ["X", "Y"])
    }

    func testMergerKeepsOffScreenRowRightBelowTheCurrentRowWhenOtherRowsAreUnrecorded() {
        let result = MRUOrderMerger.merge(
            frontToBackItemIDs: ["desktop", "chat", "editor"],
            recordedItemIDs: ["desktop", "fullScreen", "editor"]
        )

        XCTAssertEqual(result.orderedItemIDs, ["desktop", "fullScreen", "chat", "editor"])
    }

    /// Reported at 10:09:49 UTC: iTerm's second window (462) came on screen for the first time,
    /// raised together with iTerm, and the IntelliJ project used before Chrome jumped ahead of Chrome.
    func testMergerIgnoresAnUnrecordedOnScreenRowWhenPlacingOffScreenRows() {
        let result = MRUOrderMerger.merge(
            frontToBackItemIDs: ["iterm133", "idea1231", "iterm462", "chrome85", "slack109"],
            recordedItemIDs: ["iterm133", "idea1231", "chrome85", "idea1241", "slack109"]
        )

        XCTAssertEqual(result.orderedItemIDs, ["iterm133", "idea1231", "iterm462", "chrome85", "idea1241", "slack109"])
    }

    /// A window raised by a click sits higher than the list knows; rows used before it stay below it.
    func testMergerKeepsOffScreenRowBelowARowTheStackingRaised() {
        let result = MRUOrderMerger.merge(
            frontToBackItemIDs: ["B", "D", "C"],
            recordedItemIDs: ["B", "C", "X", "D"]
        )

        XCTAssertEqual(result.orderedItemIDs, ["B", "D", "C", "X"])
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


    /// Reported at 11:05:10 UTC: windows that were only ever seen on screen (never picked) had no place
    /// once they left the screen and fell to the end by title. The corrected order is saved each time
    /// the full list opens, so such a window keeps the place its stacking gave it.
    func testProviderKeepsThePlaceOfARowThatWasOnlySeenOnScreen() {
        let apps = [10, 20, 30].map { AppIdentity(processIdentifier: Int32($0), localizedName: "App\($0)") }
        let top = window(100, app: apps[0], title: "Zebra")
        let middle = window(200, app: apps[1], title: "Yak")
        let bottom = window(300, app: apps[2], title: "Apple")
        let lister = MutableCGWindowInfoLister()
        let provider = MacOSMRUOrderingProvider(windowInfoLister: lister)
        let items = [top, middle, bottom]

        lister.infoList = [windowInfo(windowID: 100, pid: 10), windowInfo(windowID: 200, pid: 20), windowInfo(windowID: 300, pid: 30)]
        _ = provider.orderingContext(for: .allAppsAndWindows, items: items)

        // The middle window moves to another Space.
        lister.infoList = [windowInfo(windowID: 100, pid: 10), windowInfo(windowID: 300, pid: 30)]
        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)

        XCTAssertEqual(context.orderedItemIDs, [top.id, middle.id, bottom.id])
    }

    func testProviderPutsARowSeenForTheFirstTimeOffScreenLastByTitle() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "App")
        let current = window(100, app: app, title: "Current")
        let zebra = window(200, app: app, title: "Zebra")
        let apple = window(300, app: app, title: "Apple")
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(infoList: [windowInfo(windowID: 100, pid: 10)])
        )

        let context = provider.orderingContext(for: .allAppsAndWindows, items: [zebra, current, apple])

        XCTAssertEqual(context.orderedItemIDs, [current.id, apple.id, zebra.id])
    }

    /// The active-app list holds one app's windows. Saving it would move all of them ahead of the
    /// other apps' windows in the shared order.
    func testActiveAppListDoesNotReorderOtherApps() {
        let editor = AppIdentity(processIdentifier: 10, localizedName: "Editor")
        let browser = AppIdentity(processIdentifier: 20, localizedName: "Browser")
        let editorFront = window(100, app: editor, title: "Front")
        let editorOtherSpace = window(101, app: editor, title: "Other Space")
        let browserWindow = window(200, app: browser, title: "Docs")
        let lister = MutableCGWindowInfoLister()
        lister.infoList = [windowInfo(windowID: 100, pid: 10), windowInfo(windowID: 200, pid: 20)]
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: lister,
            initialRecentItemIDs: [editorFront.id, browserWindow.id, editorOtherSpace.id]
        )

        _ = provider.orderingContext(for: .activeAppWindows, items: [editorFront, editorOtherSpace])
        let items = [editorFront, editorOtherSpace, browserWindow]
        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)

        XCTAssertEqual(context.orderedItemIDs, [editorFront.id, browserWindow.id, editorOtherSpace.id])
    }

    /// A full-screen window entered and left without opening the list: the app activation moves the
    /// topmost known row to the front, not the toolbar window Chrome keeps above it.
    func testAppActivationMovesTheTopmostKnownRowToTheFront() {
        let chrome = AppIdentity(processIdentifier: 645, localizedName: "Chrome")
        let code = AppIdentity(processIdentifier: 661, localizedName: "Code")
        let video = window(689, app: chrome, title: "Video")
        let editor = window(95, app: code, title: "Editor")
        let notes = window(97, app: code, title: "Notes")
        let lister = MutableCGWindowInfoLister()
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: lister,
            initialRecentItemIDs: [editor.id, notes.id, video.id]
        )
        let items = [video, editor, notes]

        lister.infoList = [windowInfo(windowID: 95, pid: 661), windowInfo(windowID: 97, pid: 661)]
        XCTAssertEqual(
            provider.orderingContext(for: .allAppsAndWindows, items: items).orderedItemIDs,
            [editor.id, notes.id, video.id]
        )

        // Into the full-screen Space by a swipe, then back to the desktop.
        lister.infoList = [windowInfo(windowID: 692, pid: 645), windowInfo(windowID: 689, pid: 645)]
        provider.recordActivatedApplication(processIdentifier: 645)
        lister.infoList = [windowInfo(windowID: 95, pid: 661), windowInfo(windowID: 97, pid: 661)]
        provider.recordActivatedApplication(processIdentifier: 661)

        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)

        XCTAssertEqual(context.orderedItemIDs, [editor.id, video.id, notes.id])
    }

    /// Reported at 11:20:39 UTC: Claude's window was listed ahead of two IntelliJ projects used after
    /// it. A project window had just appeared on top; when BokslTab's own panel activated, the window
    /// below the new one (Claude's) was taken for the one in use and moved to the front.
    func testActivationOfAnotherAppDoesNotPromoteTheRowBelowANewWindow() {
        let idea = AppIdentity(processIdentifier: 7049, localizedName: "IntelliJ IDEA")
        let claude = AppIdentity(processIdentifier: 4700, localizedName: "Claude")
        let chrome = AppIdentity(processIdentifier: 655, localizedName: "Chrome")
        let projectB = window(1231, app: idea, title: "Project B")
        let projectA = window(1211, app: idea, title: "Project A")
        let chat = window(661, app: claude, title: "Chat")
        let browser = window(85, app: chrome, title: "Docs")
        let lister = MutableCGWindowInfoLister()
        let provider = MacOSMRUOrderingProvider(windowInfoLister: lister)

        lister.infoList = [windowInfo(windowID: 1231, pid: 7049), windowInfo(windowID: 661, pid: 4700), windowInfo(windowID: 85, pid: 655)]
        _ = provider.orderingContext(for: .allAppsAndWindows, items: [projectB, chat, browser])

        // Project A's tab is clicked: its window appears on top, B's is no longer on screen.
        lister.infoList = [windowInfo(windowID: 1211, pid: 7049), windowInfo(windowID: 661, pid: 4700), windowInfo(windowID: 85, pid: 655)]
        // The switcher's panel activates; it has no window in the stacking.
        provider.recordActivatedApplication(processIdentifier: 99_999)
        let items = [projectA, projectB, chat, browser]
        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)

        XCTAssertEqual(context.orderedItemIDs, [projectA.id, projectB.id, chat.id, browser.id])
    }

    /// Reported at 10:14:51 UTC: the IntelliJ project used until 10:11 was listed below iTerm, last
    /// used at 10:09. Switching projects by clicking a tab activates no app, so only the focus event
    /// of the project window tells that it was used.
    func testWindowFocusInsideAnAppMovesThatWindowToTheFront() {
        let idea = AppIdentity(processIdentifier: 7049, localizedName: "IntelliJ IDEA")
        let chrome = AppIdentity(processIdentifier: 655, localizedName: "Chrome")
        let projectA = window(1211, app: idea, title: "Project A")
        let projectB = window(1231, app: idea, title: "Project B")
        let projectC = window(1241, app: idea, title: "Project C")
        let browser = window(85, app: chrome, title: "Docs")
        let lister = MutableCGWindowInfoLister()
        let provider = MacOSMRUOrderingProvider(windowInfoLister: lister)
        let items = [projectA, projectB, projectC, browser]

        lister.infoList = [windowInfo(windowID: 1211, pid: 7049), windowInfo(windowID: 85, pid: 655)]
        XCTAssertEqual(
            provider.orderingContext(for: .allAppsAndWindows, items: items).orderedItemIDs,
            [projectA.id, browser.id, projectB.id, projectC.id]
        )

        // The user clicks project C's tab, then project B's.
        provider.recordFocusedWindow(windowID: 1241, processIdentifier: 7049)
        provider.recordFocusedWindow(windowID: 1231, processIdentifier: 7049)
        lister.infoList = [windowInfo(windowID: 1231, pid: 7049), windowInfo(windowID: 85, pid: 655)]
        let context = provider.orderingContext(for: .allAppsAndWindows, items: items)

        XCTAssertEqual(context.orderedItemIDs, [projectB.id, projectC.id, projectA.id, browser.id])
    }

    func testProviderMapsStableTitleHistoryAfterATabRowTitleChanges() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "IntelliJ IDEA")
        let currentTitle = "BokslTab – Models.swift"
        let current = SwitcherItem(
            app: app,
            kind: .window(WindowIdentity(
                windowID: 300,
                ownerProcessIdentifier: 10,
                title: currentTitle,
                tab: WindowTabIdentity(parentWindowID: 300, index: 1, title: currentTitle)
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

        // The other tab has no place yet, so it follows; the parent window stands for the selected tab.
        XCTAssertEqual(context.orderedItemIDs, [selectedTab.id, firstTab.id])
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


    private func window(_ windowID: UInt32, app: AppIdentity, title: String) -> SwitcherItem {
        SwitcherItem(app: app, kind: .window(WindowIdentity(
            windowID: windowID,
            ownerProcessIdentifier: app.processIdentifier,
            title: title
        )))
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
