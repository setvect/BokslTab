import ApplicationServices
import BokslTabCore
import CoreGraphics
import XCTest
@testable import BokslTabMacOSAdapters

/// A full-screen window has a Space of its own, so it is never on screen together with desktop windows.
final class OtherSpaceWindowTests: XCTestCase {
    private let maximized = CGRect(x: 0, y: 30, width: 2560, height: 1410)
    private let secondDisplay = CGRect(x: 2560, y: 73, width: 2560, height: 1410)
    private let fullScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let chatFrame = CGRect(x: 71, y: 436, width: 577, height: 675)

    private func info(
        pid: Int32,
        windowID: UInt32,
        bounds: CGRect,
        title: String? = nil,
        onScreen: Bool = true,
        owner: String = "Google Chrome"
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: bounds.dictionaryRepresentation
        ]
        if let title { info[kCGWindowName as String] = title }
        if onScreen { info[kCGWindowIsOnscreen as String] = NSNumber(value: true) }
        return info
    }

    private func row(_ windowID: UInt32, pid: Int32, title: String?) -> WindowSnapshot {
        WindowSnapshot(
            identity: WindowIdentity(windowID: windowID, ownerProcessIdentifier: pid, title: title),
            bounds: maximized,
            ownerName: "Google Chrome"
        )
    }

    private func titles(_ windows: [WindowIdentity], file: StaticString = #filePath, line: UInt = #line) -> [UInt32: String] {
        XCTAssertEqual(windows.count, Set(windows.map(\.windowID)).count, "a window is listed twice", file: file, line: line)
        return Dictionary(windows.map { ($0.windowID, $0.title ?? "") }) { first, _ in first }
    }

    // MARK: Remembered windows

    func testRememberedWindowOutsideVisibleSpacesIsListedWithItsLastTitle() {
        let registry = SeenWindowRegistry()
        registry.recordOnScreen([row(151, pid: 645, title: "Docs"), row(689, pid: 645, title: "Video")])

        let snapshots = registry.offScreenSnapshots(
            processIdentifiers: [645],
            excludingWindowIDs: [151],
            windowInfo: { $0 == 689 ? self.info(pid: 645, windowID: 689, bounds: self.fullScreen, onScreen: false) : nil }
        )

        XCTAssertEqual(snapshots.map(\.identity.windowID), [689])
        XCTAssertEqual(snapshots.first?.identity.title, "Video")
        XCTAssertEqual(snapshots.first?.bounds, fullScreen)
    }

    func testRegistryForgetsClosedOrReusedWindowsAndSkipsMinimizedOrVisibleOnes() {
        let registry = SeenWindowRegistry()
        registry.recordOnScreen([
            row(10, pid: 1, title: "Closed"),
            row(11, pid: 1, title: "Reused"),
            row(12, pid: 1, title: "Minimized"),
            row(13, pid: 1, title: "Visible")
        ])
        registry.applyAccessibilityState([
            1: [AccessibilityWindowSnapshot(windowID: 12, title: "Minimized", frame: maximized, isMinimized: true)]
        ])

        let snapshots = registry.offScreenSnapshots(processIdentifiers: [1], excludingWindowIDs: [], windowInfo: { windowID in
            switch windowID {
            case 11: return self.info(pid: 2, windowID: 11, bounds: self.maximized, onScreen: false)
            case 12: return self.info(pid: 1, windowID: 12, bounds: self.maximized, onScreen: false)
            case 13: return self.info(pid: 1, windowID: 13, bounds: self.maximized)
            default: return nil
            }
        })

        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(registry.count, 2)
    }

    func testRegistryRemembersOnlyTitledWindowServerRows() {
        let registry = SeenWindowRegistry()
        registry.recordOnScreen([
            row(20, pid: 1, title: nil),
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: 21,
                    ownerProcessIdentifier: 1,
                    title: "Project",
                    tab: WindowTabIdentity(parentWindowID: 21, index: 0, title: "Project")
                ),
                bounds: maximized
            ),
            WindowSnapshot(
                identity: WindowIdentity(windowID: 22, ownerProcessIdentifier: 1, title: "Hidden", source: .accessibilityOnly),
                bounds: maximized
            )
        ])

        XCTAssertEqual(registry.count, 0)
    }

    func testRememberedTitlesFillOnlyRowsStillWithoutATitleOfTheSameApp() {
        let registry = SeenWindowRegistry()
        registry.recordOnScreen([
            row(95, pid: 661, title: "A"),
            row(97, pid: 661, title: "B"),
            row(99, pid: 661, title: "C"),
            row(101, pid: 661, title: "D")
        ])

        let rows = registry.applyRememberedTitles(to: [
            row(95, pid: 661, title: nil),
            row(97, pid: 661, title: "B · edited"),
            row(99, pid: 661, title: "Google Chrome"),
            row(98, pid: 661, title: nil),
            row(101, pid: 662, title: nil)
        ])

        XCTAssertEqual(rows.map(\.identity.title), ["A", "B · edited", "C", nil, nil])
    }

    // MARK: Remembered AX handles

    func testRememberedHandlesAreKeyedByAppAndWindowNumber() {
        let cache = AccessibilityWindowElementCache()
        let handle = AXUIElementCreateApplication(999_501)
        cache.record(handle, windowID: 151, processIdentifier: 645)

        XCTAssertNotNil(cache.element(windowID: 151, processIdentifier: 645))
        XCTAssertNil(cache.element(windowID: 151, processIdentifier: 646))
        XCTAssertNil(cache.element(windowID: 152, processIdentifier: 645))

        cache.retainOnly([646])
        XCTAssertNil(cache.element(windowID: 151, processIdentifier: 645))

        cache.record(handle, windowID: 151, processIdentifier: 645)
        cache.remove(windowID: 151, processIdentifier: 645)
        XCTAssertEqual(cache.count, 0)
    }

    func testRememberedHandlesKeepTheMostRecentlySeenWindows() {
        let cache = AccessibilityWindowElementCache(maxEntries: 2)
        let handle = AXUIElementCreateApplication(999_502)
        cache.record(handle, windowID: 1, processIdentifier: 7)
        cache.record(handle, windowID: 2, processIdentifier: 7)
        cache.record(handle, windowID: 1, processIdentifier: 7)
        cache.record(handle, windowID: 3, processIdentifier: 7)

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.element(windowID: 1, processIdentifier: 7))
        XCTAssertNil(cache.element(windowID: 2, processIdentifier: 7))
        XCTAssertNotNil(cache.element(windowID: 3, processIdentifier: 7))
    }

    /// Detail refreshes run while a window is visible, which is the only time AX hands out its handle.
    func testDetailRefreshRemembersHandlesOfNumberedWindows() {
        let pid: Int32 = 999_503
        let window = AXUIElementCreateApplication(999_504)
        var api = testAccessibilityAPI()
        api.copyAttribute = { element, attribute, output in
            var owner: pid_t = 0
            _ = AXUIElementGetPid(element, &owner)
            switch (owner == pid, attribute as String) {
            case (true, kAXWindowsAttribute):
                output.pointee = [window] as CFArray
            case (false, kAXPositionAttribute):
                var origin = CGPoint(x: 0, y: 30)
                output.pointee = AXValueCreate(.cgPoint, &origin)
            case (false, kAXSizeAttribute):
                var size = CGSize(width: 2560, height: 1410)
                output.pointee = AXValueCreate(.cgSize, &size)
            case (false, kAXTitleAttribute):
                output.pointee = "Docs" as CFString
            default:
                return .attributeUnsupported
            }
            return .success
        }
        api.windowID = { element, windowID in
            guard CFEqual(element, window) else { return .failure }
            windowID.pointee = 151
            return .success
        }
        let accessibility = MacOSAccessibilityService(api: api)
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { [self.info(pid: pid, windowID: 151, bounds: self.maximized, owner: "Test App")] },
            windowInfoForWindowID: { _ in nil },
            isAccessibilityTrusted: { true }
        )

        provider.requestRefresh(including: [])
        accessibility.workerQueue.sync {}

        XCTAssertNotNil(accessibility.windowElements.element(windowID: 151, processIdentifier: pid))
        XCTAssertEqual(provider.windowsForAllApps().first?.title, "Docs")
    }

    // MARK: Catalog

    /// Reported at 22:35: the full-screen Chrome window was missing from the desktop list, and the
    /// desktop Chrome window was missing from the full-screen list.
    func testCatalogListsChromeWindowsFromBothTheDesktopAndTheFullScreenSpace() {
        let chrome = AppIdentity(processIdentifier: 999_645, localizedName: "Google Chrome")
        let accessibility = MacOSAccessibilityService()
        var onScreen = [
            info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized),
            info(pid: chrome.processIdentifier, windowID: 689, bounds: secondDisplay)
        ]
        var offScreen: [UInt32: [String: Any]] = [:]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { onScreen },
            windowInfoForWindowID: { offScreen[$0] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                [
                    AccessibilityWindowSnapshot(windowID: 151, title: "Docs", frame: self.maximized),
                    AccessibilityWindowSnapshot(windowID: 689, title: "Video", frame: self.secondDisplay)
                ]
            }
        )
        provider.requestRefresh(including: [chrome])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [chrome])), [151: "Docs", 689: "Video"])

        // 689 goes full screen and the user is in its Space.
        onScreen = [info(pid: chrome.processIdentifier, windowID: 689, bounds: fullScreen)]
        offScreen = [151: info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized, onScreen: false)]
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [chrome])), [151: "Docs", 689: "Video"])

        // Back on the desktop.
        onScreen = [info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized)]
        offScreen = [689: info(pid: chrome.processIdentifier, windowID: 689, bounds: fullScreen, onScreen: false)]
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [chrome])), [151: "Docs", 689: "Video"])

        // The full-screen window is closed.
        offScreen = [:]
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [chrome])), [151: "Docs"])
    }

    /// The first list in a full-screen Space used to hold only that window: other apps came only from
    /// AX details, which are discarded after five seconds.
    func testCatalogListsRememberedWindowsOfOtherAppsWithoutAccessibilityDetails() {
        let chrome = AppIdentity(processIdentifier: 999_646, localizedName: "Google Chrome")
        let kakao = AppIdentity(processIdentifier: 999_667, localizedName: "KakaoTalk")
        var onScreen = [
            info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized, title: "Docs"),
            info(pid: kakao.processIdentifier, windowID: 78, bounds: chatFrame, title: "친구", owner: "KakaoTalk")
        ]
        var offScreen: [UInt32: [String: Any]] = [:]
        let provider = MacOSWindowCatalogProvider(
            accessibility: MacOSAccessibilityService(),
            windowInfoList: { onScreen },
            windowInfoForWindowID: { offScreen[$0] },
            isAccessibilityTrusted: { true }
        )
        _ = provider.windowsForAllApps(including: [chrome, kakao])

        onScreen = [info(pid: chrome.processIdentifier, windowID: 689, bounds: fullScreen, title: "Video")]
        offScreen = [
            151: info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized, onScreen: false),
            78: info(pid: kakao.processIdentifier, windowID: 78, bounds: chatFrame, onScreen: false, owner: "KakaoTalk")
        ]

        XCTAssertEqual(
            titles(provider.windowsForAllApps(including: [chrome, kakao])),
            [689: "Video", 151: "Docs", 78: "친구"]
        )
    }

    /// Reported at 10:25 UTC: back from a full-screen Space, one of two maximized VS Code windows was
    /// missing from the list. AX details taken in that Space hold only the app's main window and are
    /// reused for five seconds. The other window had no title, so it was dropped as an untitled
    /// duplicate of the titled window with the same frame.
    func testSameSizeWindowKeepsItsRowWhenDetailsFromAnotherSpaceLeaveItOut() {
        let code = AppIdentity(processIdentifier: 999_661, localizedName: "Code")
        let accessibility = MacOSAccessibilityService()
        var time: TimeInterval = 100
        let desktop = [
            info(pid: code.processIdentifier, windowID: 97, bounds: maximized, owner: "Visual Studio Code"),
            info(pid: code.processIdentifier, windowID: 95, bounds: maximized, owner: "Visual Studio Code")
        ]
        var onScreen = desktop
        var offScreen: [UInt32: [String: Any]] = [:]
        var details = [
            AccessibilityWindowSnapshot(windowID: 95, title: "A — repo", frame: maximized),
            AccessibilityWindowSnapshot(windowID: 97, title: "B — repo", frame: maximized)
        ]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { onScreen },
            windowInfoForWindowID: { offScreen[$0] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in details },
            now: { time }
        )
        provider.requestRefresh(including: [code])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [code])), [95: "A — repo", 97: "B — repo"])

        // In Chrome's full-screen Space, AX lists no VS Code window but still returns the main one.
        time += 1
        onScreen = []
        offScreen = [
            95: info(pid: code.processIdentifier, windowID: 95, bounds: maximized, onScreen: false, owner: "Visual Studio Code"),
            97: info(pid: code.processIdentifier, windowID: 97, bounds: maximized, onScreen: false, owner: "Visual Studio Code")
        ]
        details = [AccessibilityWindowSnapshot(windowID: 97, title: "B — repo", frame: maximized)]
        provider.requestRefresh(including: [code])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [code])), [95: "A — repo", 97: "B — repo"])

        // Back on the desktop, the list is read before the next refresh arrives.
        time += 1
        onScreen = desktop
        offScreen = [:]
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [code])), [95: "A — repo", 97: "B — repo"])
    }

    /// Five seconds after the last list the AX details are discarded. The title cache keeps one title
    /// per app, so only the topmost of two maximized windows got a title and the other was dropped.
    func testSameSizeWindowsKeepTheirRowsAfterDetailsExpire() {
        let code = AppIdentity(processIdentifier: 999_662, localizedName: "Code")
        let accessibility = MacOSAccessibilityService()
        var time: TimeInterval = 100
        let onScreen = [
            info(pid: code.processIdentifier, windowID: 97, bounds: maximized, owner: "Visual Studio Code"),
            info(pid: code.processIdentifier, windowID: 95, bounds: maximized, owner: "Visual Studio Code")
        ]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { onScreen },
            windowInfoForWindowID: { _ in nil },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                [
                    AccessibilityWindowSnapshot(windowID: 95, title: "A — repo", frame: self.maximized),
                    AccessibilityWindowSnapshot(windowID: 97, title: "B — repo", frame: self.maximized)
                ]
            },
            now: { time }
        )
        provider.requestRefresh(including: [code])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [code])), [95: "A — repo", 97: "B — repo"])

        time += 6
        XCTAssertEqual(titles(provider.windowsForAllApps(including: [code])), [95: "A — repo", 97: "B — repo"])
    }

    func testRevokedPermissionForgetsRememberedWindows() {
        let chrome = AppIdentity(processIdentifier: 999_647, localizedName: "Google Chrome")
        var trusted = true
        var onScreen = [info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized, title: "Docs")]
        let offScreen: [UInt32: [String: Any]] = [
            151: info(pid: chrome.processIdentifier, windowID: 151, bounds: maximized, onScreen: false)
        ]
        let provider = MacOSWindowCatalogProvider(
            accessibility: MacOSAccessibilityService(),
            windowInfoList: { onScreen },
            windowInfoForWindowID: { offScreen[$0] },
            isAccessibilityTrusted: { trusted }
        )
        _ = provider.windowsForAllApps(including: [chrome])

        trusted = false
        _ = provider.windowsForAllApps(including: [chrome])
        trusted = true
        onScreen = []

        XCTAssertTrue(provider.windowsForAllApps(including: [chrome]).isEmpty)
    }
}
