import ApplicationServices
import BokslTabCore
import CoreGraphics
import XCTest
@testable import BokslTabMacOSAdapters

/// Each tab of a native tab group (IntelliJ projects, Finder tabs) is a window of its own. Only the
/// selected one is on screen and in the AX window list; the others still exist under their numbers.
final class NativeTabWindowTests: XCTestCase {
    private let groupFrame = CGRect(x: 0, y: 30, width: 2560, height: 1410)
    private let idea = AppIdentity(
        processIdentifier: 999_049,
        bundleIdentifier: "com.jetbrains.intellij",
        localizedName: "IntelliJ IDEA"
    )

    private enum Shown { case onScreen, otherSpace, noSpace }

    private func info(_ windowID: UInt32, pid: Int32, _ shown: Shown, title: String? = nil, owner: String = "IntelliJ IDEA") -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: groupFrame.dictionaryRepresentation
        ]
        if let title { info[kCGWindowName as String] = title }
        switch shown {
        case .onScreen: info[kCGWindowIsOnscreen as String] = NSNumber(value: true)
        case .otherSpace: break
        case .noSpace: info[WindowServerWindowAccess.orderedOutKey] = true
        }
        return info
    }

    private func tabBar(of windowID: UInt32, title: String, selected: String, tabs: [String]) -> AccessibilityWindowSnapshot {
        AccessibilityWindowSnapshot(
            windowID: windowID,
            title: title,
            frame: groupFrame,
            tabs: tabs.enumerated().map { index, tab in
                AccessibilityTabSnapshot(index: index, title: tab, isSelected: tab == selected, source: .windowTabGroup)
            }
        )
    }

    private func rows(_ windows: [WindowIdentity], file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let rows = windows.map { window in
            window.tab.map { "tab of \($0.parentWindowID): \($0.title)" } ?? "\(window.windowID): \(window.title ?? "")"
        }
        XCTAssertEqual(rows.count, Set(rows).count, "a row is listed twice", file: file, line: line)
        return rows.sorted()
    }

    // MARK: Catalog

    /// Reported at 10:09:36 UTC and on the four switches after it: right after changing projects the
    /// list showed the current project twice (its window under the previous project's title, plus a
    /// row made from its own title) and the project just left was missing. A project also changed
    /// its row ID between a window number, a number hashed from its title, and a tab index.
    func testProjectsOfATabGroupKeepTheirWindowRowsAcrossSwitches() {
        let pid = idea.processIdentifier
        let accessibility = MacOSAccessibilityService()
        var time: TimeInterval = 100
        var onScreen = [info(1211, pid: pid, .onScreen)]
        var existing: [UInt32: [String: Any]] = [
            1231: info(1231, pid: pid, .noSpace),
            1241: info(1241, pid: pid, .noSpace)
        ]
        var details = [tabBar(of: 1211, title: "Project A – Main.kt", selected: "Project A", tabs: ["Project A", "Project B", "Project C"])]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { onScreen },
            windowInfoForWindowID: { existing[$0] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in details },
            now: { time }
        )
        func refresh() {
            time += 1
            provider.requestRefresh(including: [idea])
            accessibility.workerQueue.sync {}
        }

        // Projects B and C have not been seen yet: only their tabs are known.
        refresh()
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [idea])), [
            "1211: Project A – Main.kt", "tab of 1211: Project B", "tab of 1211: Project C"
        ])

        // The user clicks project B's tab inside IntelliJ. The focus event reports its window; the
        // details still describe A's window, which is an unselected tab now.
        onScreen = [info(1231, pid: pid, .onScreen)]
        existing = [1211: info(1211, pid: pid, .noSpace), 1241: info(1241, pid: pid, .noSpace)]
        accessibility.knownWindows.record(
            windowID: 1231, processIdentifier: pid, title: "Project B – App.kt", ownerName: nil, isMinimized: false
        )
        let rightAfterTheSwitch = rows(provider.windowsForAllApps(including: [idea]))
        XCTAssertEqual(rightAfterTheSwitch, [
            "1211: Project A – Main.kt", "1231: Project B – App.kt", "tab of 1231: Project C"
        ])

        // Fresh details change nothing: the first list was already complete.
        details = [tabBar(of: 1231, title: "Project B – App.kt", selected: "Project B", tabs: ["Project A", "Project B", "Project C"])]
        refresh()
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [idea])), rightAfterTheSwitch)

        // Project C is picked from its tab row and becomes a window row like the others.
        onScreen = [info(1241, pid: pid, .onScreen)]
        existing = [1211: info(1211, pid: pid, .noSpace), 1231: info(1231, pid: pid, .noSpace)]
        details = [tabBar(of: 1241, title: "Project C – Lib.kt", selected: "Project C", tabs: ["Project A", "Project B", "Project C"])]
        refresh()
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [idea])), [
            "1211: Project A – Main.kt", "1231: Project B – App.kt", "1241: Project C – Lib.kt"
        ])

        // Project A is closed: its window is destroyed and its tab is gone.
        existing = [1231: info(1231, pid: pid, .noSpace)]
        details = [tabBar(of: 1241, title: "Project C – Lib.kt", selected: "Project C", tabs: ["Project B", "Project C"])]
        refresh()
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [idea])), [
            "1231: Project B – App.kt", "1241: Project C – Lib.kt"
        ])
    }

    /// Reported at 11:12:39 UTC: a project picked from its tab row for the first time was listed
    /// twice when the list opened within a second, as an untitled window and again as its tab, with
    /// the tab as the default selection. IntelliJ was still switching and had not answered yet.
    func testWindowBroughtUpByAPressedTabTakesThatTabsTitle() {
        let pid = idea.processIdentifier
        let accessibility = MacOSAccessibilityService()
        var time: TimeInterval = 100
        var onScreen = [info(1241, pid: pid, .onScreen)]
        var existing: [UInt32: [String: Any]] = [1231: info(1231, pid: pid, .noSpace)]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { onScreen },
            windowInfoForWindowID: { existing[$0] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                [self.tabBar(of: 1241, title: "Project C – Lib.kt", selected: "Project C", tabs: ["Project B", "Project C"])]
            },
            now: { time }
        )
        provider.requestRefresh(including: [idea])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [idea])), [
            "1241: Project C – Lib.kt", "tab of 1241: Project B"
        ])

        // The tab row is pressed; window 1231 comes on screen before any new detail arrives.
        accessibility.knownWindows.expectWindow(forTabTitled: "Project B", processIdentifier: pid, now: time)
        time += 0.9
        onScreen = [info(1231, pid: pid, .onScreen)]
        existing = [1241: info(1241, pid: pid, .noSpace)]

        XCTAssertEqual(rows(provider.windowsForAllApps(including: [idea])), [
            "1231: Project B", "1241: Project C – Lib.kt"
        ])
    }

    func testExpectedTabTitleIsNotGivenToAKnownOrLateWindow() {
        let registry = SeenWindowRegistry()
        let unknown = WindowSnapshot(
            identity: WindowIdentity(windowID: 1231, ownerProcessIdentifier: 49),
            bounds: groupFrame,
            ownerName: "IntelliJ IDEA"
        )

        registry.expectWindow(forTabTitled: "Project B", processIdentifier: 49, now: 100)
        XCTAssertNil(registry.applyExpectedTabTitles(to: [unknown], now: 106)[0].identity.title, "too late to be that tab's window")

        registry.expectWindow(forTabTitled: "Project B", processIdentifier: 49, now: 100)
        let other = WindowSnapshot(
            identity: WindowIdentity(windowID: 1299, ownerProcessIdentifier: 49),
            bounds: groupFrame,
            ownerName: "IntelliJ IDEA"
        )
        XCTAssertEqual(registry.applyExpectedTabTitles(to: [unknown, other], now: 101).map(\.identity.title), [nil, nil], "two candidates: no guess")
        XCTAssertEqual(registry.applyExpectedTabTitles(to: [unknown], now: 101)[0].identity.title, "Project B")
        XCTAssertEqual(registry.tabKeys(windowIDs: [1231], processIdentifier: 49), [1231: ["project b"]])
        XCTAssertNil(registry.applyExpectedTabTitles(to: [other], now: 101)[0].identity.title, "one tab names one window")
    }

    /// A window its app closed without destroying it is shown on no Space, like an unselected tab,
    /// but no tab bar names it.
    func testWindowClosedWithoutBeingDestroyedIsNotListed() {
        let chrome = AppIdentity(processIdentifier: 999_645, localizedName: "Google Chrome")
        var onScreen = [info(500, pid: chrome.processIdentifier, .onScreen, title: "Settings", owner: "Google Chrome")]
        var existing: [UInt32: [String: Any]] = [:]
        let provider = MacOSWindowCatalogProvider(
            accessibility: MacOSAccessibilityService(),
            windowInfoList: { onScreen },
            windowInfoForWindowID: { existing[$0] },
            isAccessibilityTrusted: { true }
        )
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [chrome])), ["500: Settings"])

        onScreen = []
        existing = [500: info(500, pid: chrome.processIdentifier, .noSpace, owner: "Google Chrome")]
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [chrome])), [])

        // On another desktop it is still a window the user can switch to.
        existing = [500: info(500, pid: chrome.processIdentifier, .otherSpace, owner: "Google Chrome")]
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [chrome])), ["500: Settings"])
    }

    /// Reported at 10:08:52 UTC: after 86 idle seconds the list opened with 5 rows and grew to 8.
    /// Rows known only through AX details (here a hidden app's window) were dropped with the details.
    func testFirstListAfterIdleKeepsRowsKnownOnlyThroughDetails() {
        let notes = AppIdentity(processIdentifier: 999_700, localizedName: "Notes")
        let accessibility = MacOSAccessibilityService()
        var time: TimeInterval = 100
        var existing: [UInt32: [String: Any]] = [700: info(700, pid: notes.processIdentifier, .noSpace, owner: "Notes")]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { [] },
            windowInfoForWindowID: { existing[$0] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                [AccessibilityWindowSnapshot(windowID: 700, title: "Shopping list", frame: self.groupFrame)]
            },
            now: { time }
        )
        provider.requestRefresh(including: [notes])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [notes])), ["700: Shopping list"])

        time += 86
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [notes])), ["700: Shopping list"])

        // Old details must not bring back a window that was closed meanwhile.
        existing = [:]
        XCTAssertEqual(rows(provider.windowsForAllApps(including: [notes])), [])
    }

    // MARK: Registry

    func testWindowShownOnNoSpaceIsListedOnlyWhenATabBarNamesIt() {
        let registry = SeenWindowRegistry()
        registry.record(windowID: 1231, processIdentifier: 49, title: "Project B – App.kt", ownerName: "IntelliJ IDEA", isMinimized: false)
        registry.record(windowID: 1241, processIdentifier: 49, title: "Project C – Lib.kt", ownerName: "IntelliJ IDEA", isMinimized: false)
        let existing: [UInt32: [String: Any]] = [
            1231: info(1231, pid: 49, .noSpace),
            1241: info(1241, pid: 49, .noSpace)
        ]
        var askedKeys: [Set<String>] = []

        let snapshots = registry.offScreenSnapshots(
            processIdentifiers: [49],
            excludingWindowIDs: [],
            windowInfo: { existing[$0] },
            isUnselectedTab: { entry in
                askedKeys.append(entry.tabKeys)
                return entry.tabKeys.contains("project c")
            }
        )

        XCTAssertEqual(snapshots.map(\.identity.windowID), [1241])
        XCTAssertEqual(snapshots.first?.identity.title, "Project C – Lib.kt")
        XCTAssertEqual(Set(askedKeys), [["project b"], ["project c"]])
        XCTAssertEqual(registry.count, 2, "a window shown on no Space still exists and is not forgotten")
    }

    func testRegistryRemembersTheTabTitleOfASelectedWindow() {
        let registry = SeenWindowRegistry()
        registry.record(windowID: 1211, processIdentifier: 49, title: "~/work/a – Main.kt", ownerName: nil, isMinimized: false)
        registry.applyAccessibilityState([49: [
            tabBar(of: 1211, title: "~/work/a – Main.kt", selected: "Project A", tabs: ["Project A", "Project B"])
        ]])
        // A later sighting without tab details keeps what was learned.
        registry.record(windowID: 1211, processIdentifier: 49, title: "~/work/a – Other.kt", ownerName: nil, isMinimized: false)

        XCTAssertEqual(
            registry.tabKeys(windowIDs: [1211, 9999], processIdentifier: 49),
            [1211: ["~/work/a", "project a"]]
        )
        XCTAssertEqual(registry.tabKeys(windowIDs: [1211], processIdentifier: 50), [:])
    }

    func testRegistryForgetsWindowsOfAppsThatAreGone() {
        let registry = SeenWindowRegistry()
        registry.record(windowID: 1, processIdentifier: 10, title: "Kept", ownerName: nil, isMinimized: false)
        registry.record(windowID: 2, processIdentifier: 20, title: "Gone", ownerName: nil, isMinimized: false)

        registry.retainOnly([10])

        XCTAssertEqual(registry.count, 1)
    }

    func testPlacementTellsAWindowOnAnotherSpaceFromOneShownOnNoSpace() {
        XCTAssertEqual(WindowServerPlacement(windowInfo: info(1, pid: 49, .onScreen), processIdentifier: 49), .onScreen)
        XCTAssertEqual(WindowServerPlacement(windowInfo: info(1, pid: 49, .otherSpace), processIdentifier: 49), .offScreen)
        XCTAssertEqual(WindowServerPlacement(windowInfo: info(1, pid: 49, .noSpace), processIdentifier: 49), .orderedOut)
        XCTAssertEqual(WindowServerPlacement(windowInfo: info(1, pid: 50, .noSpace), processIdentifier: 49), .missing)
    }

    // MARK: Focus events

    /// A project selected by clicking its tab is never a row while the list is open. Its number, title
    /// and handle are read when the app reports its windows.
    func testWindowsReportedByATabAppAreRememberedByNumber() {
        let pid: Int32 = 999_050
        let window = AXUIElementCreateApplication(999_051)
        var api = testAccessibilityAPI()
        api.copyAttribute = { element, attribute, output in
            var owner: pid_t = 0
            _ = AXUIElementGetPid(element, &owner)
            switch (owner == pid, attribute as String) {
            case (true, kAXFocusedWindowAttribute):
                output.pointee = window
            case (false, kAXPositionAttribute):
                var origin = CGPoint(x: 0, y: 30)
                output.pointee = AXValueCreate(.cgPoint, &origin)
            case (false, kAXSizeAttribute):
                var size = CGSize(width: 2560, height: 1410)
                output.pointee = AXValueCreate(.cgSize, &size)
            case (false, kAXTitleAttribute):
                output.pointee = "Project B – App.kt" as CFString
            default:
                return .attributeUnsupported
            }
            return .success
        }
        api.windowID = { element, windowID in
            guard CFEqual(element, window) else { return .failure }
            windowID.pointee = 1231
            return .success
        }
        let accessibility = MacOSAccessibilityService(api: api)

        accessibility.workerQueue.sync {
            let _: Void? = accessibility.perform(for: pid) { query in
                accessibility.eventObserver.recordCurrentWindows(for: pid, query: query)
            }
        }

        XCTAssertEqual(accessibility.knownWindows.tabKeys(windowIDs: [1231], processIdentifier: pid), [1231: ["project b"]])
        XCTAssertNotNil(accessibility.windowElements.element(windowID: 1231, processIdentifier: pid))

        // An event reports the window that has focus now, whatever element the event itself carried.
        var focused: [UInt32] = []
        accessibility.windowFocusHandler = { windowID, _ in focused.append(windowID) }
        accessibility.workerQueue.sync {
            let _: Void? = accessibility.perform(for: pid) { query in
                accessibility.eventObserver.handleEvent(
                    element: AXUIElementCreateApplication(pid),
                    notification: kAXFocusedWindowChangedNotification as String,
                    processIdentifier: pid,
                    query: query
                )
            }
        }
        XCTAssertEqual(focused, [1231])
    }
}
