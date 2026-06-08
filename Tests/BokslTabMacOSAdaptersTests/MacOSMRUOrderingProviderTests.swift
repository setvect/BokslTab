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

    func testProviderUsesActivationHistoryBeforeCoreGraphicsFallbackOrder() {
        let app = AppIdentity(processIdentifier: 10, localizedName: "App")
        let current = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 300, ownerProcessIdentifier: 10, title: "Current")))
        let previous = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 200, ownerProcessIdentifier: 10, title: "Previous")))
        let older = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 100, ownerProcessIdentifier: 10, title: "Older")))
        let provider = MacOSMRUOrderingProvider(
            windowInfoLister: FakeCGWindowInfoLister(
                infoList: [
                    windowInfo(windowID: 300, pid: 10),
                    windowInfo(windowID: 100, pid: 10),
                    windowInfo(windowID: 200, pid: 10)
                ]
            ),
            initialRecentItemIDs: [previous.id, older.id]
        )

        let context = provider.orderingContext(for: .activeAppWindows, items: [older, previous, current])
        let ordered = SwitcherMRUOrderer.order(items: [older, previous, current], context: context)

        XCTAssertEqual(context.orderedItemIDs, [current.id, previous.id, older.id])
        XCTAssertEqual(context.currentItemID, current.id)
        XCTAssertEqual(context.sourceDescription, "workspace-activation-history+cg-window-list-front-to-back")
        XCTAssertEqual(ordered.map(\.title), ["Current", "Previous", "Older"])
        XCTAssertEqual(SwitcherMRUOrderer.defaultSelectedIndex(orderedItems: ordered, context: context), 1)
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
