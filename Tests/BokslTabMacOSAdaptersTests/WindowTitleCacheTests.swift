@testable import BokslTabMacOSAdapters
import BokslTabCore
import CoreGraphics
import XCTest

final class WindowTitleCacheTests: XCTestCase {
    func testWindowTitleCacheDoesNotApplyShortAuxiliarySurfaces() {
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
        let weakLiveWindow = WindowSnapshot(
            identity: WindowIdentity(windowID: 11723, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            ownerName: "Brave Browser"
        )

        let snapshots = cache.applyCachedTitles(to: [weakLiveWindow])

        XCTAssertNil(snapshots[0].identity.title)
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
        let weakLiveWindow = WindowSnapshot(
            identity: WindowIdentity(windowID: 11723, ownerProcessIdentifier: 42, title: nil),
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            ownerName: "Code"
        )

        let snapshots = cache.applyCachedTitles(to: [weakLiveWindow])

        XCTAssertNil(snapshots[0].identity.title)
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
        _ = cache.applyCachedTitles(to: [
            WindowSnapshot(
                identity: WindowIdentity(windowID: 11, ownerProcessIdentifier: 1, title: nil),
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "App 1"
            )
        ])

        cache.record([snapshot(processIdentifier: 3, title: "Three")])

        let snapshots = cache.applyCachedTitles(to: [
            WindowSnapshot(
                identity: WindowIdentity(windowID: 11, ownerProcessIdentifier: 1, title: nil),
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "App 1"
            ),
            WindowSnapshot(
                identity: WindowIdentity(windowID: 22, ownerProcessIdentifier: 2, title: nil),
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "App 2"
            ),
            WindowSnapshot(
                identity: WindowIdentity(windowID: 33, ownerProcessIdentifier: 3, title: nil),
                bounds: CGRect(x: 0, y: 0, width: 900, height: 700),
                ownerName: "App 3"
            )
        ])

        XCTAssertEqual(snapshots.map(\.identity.title), ["One", nil, "Three"])
    }

}
