import XCTest
@testable import BokslTabCore

final class SwitcherRefreshTests: XCTestCase {
    private let app = AppIdentity(processIdentifier: 1, localizedName: "App")

    private func window(_ id: UInt32, title: String = "Basic") -> SwitcherItem {
        SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: id, ownerProcessIdentifier: 1, title: title)))
    }

    private func tab(_ index: Int, selected: Bool = false) -> SwitcherItem {
        SwitcherItem(app: app, kind: .window(WindowIdentity(
            windowID: 10,
            ownerProcessIdentifier: 1,
            title: "Tab \(index)",
            tab: WindowTabIdentity(parentWindowID: 10, index: index, title: "Tab \(index)", isSelected: selected)
        )))
    }

    func testAppFallbackBecomesFirstWindowOfTheSameApp() {
        var state = SwitcherState(mode: .activeAppWindows, items: [SwitcherItem(app: app, kind: .app)])
        XCTAssertTrue(state.mergeRefreshedItems([window(10), window(20)]))
        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(state.selectedItem?.id, window(10).id)
    }

    func testAppFallbackDoesNotSelectAnotherApp() {
        let other = AppIdentity(processIdentifier: 2, localizedName: "Other")
        var state = SwitcherState(mode: .activeAppWindows, items: [SwitcherItem(app: other, kind: .app)])
        XCTAssertFalse(state.mergeRefreshedItems([window(10)]))
        XCTAssertEqual(state.selectedItem?.app, other)
    }

    func testEnrichmentPreservesOrderAndUserSelection() {
        var state = SwitcherState(mode: .allAppsAndWindows, items: [window(10), window(20)], selectedIndex: 1)
        XCTAssertTrue(state.mergeRefreshedItems([window(20, title: "Detailed"), window(10), window(30)]))
        XCTAssertEqual(state.items.map(\.id), [window(10).id, window(20).id, window(30).id])
        XCTAssertEqual(state.selectedItem?.id, window(20).id)
        XCTAssertEqual(state.selectedItem?.title, "Detailed")
    }

    func testSelectedParentBecomesItsCurrentlySelectedTab() {
        var state = SwitcherState(mode: .allAppsAndWindows, items: [window(20), window(10)], selectedIndex: 1)
        XCTAssertTrue(state.mergeRefreshedItems([tab(0), tab(1, selected: true), window(20)]))
        XCTAssertEqual(state.items.map(\.id), [window(20).id, tab(0).id, tab(1).id])
        XCTAssertEqual(state.selectedItem?.id, tab(1).id)
    }

    func testMissingSelectedTabDoesNotRetargetToAnotherTab() {
        var state = SwitcherState(mode: .allAppsAndWindows, items: [tab(0), tab(1)], selectedIndex: 1)
        let previous = state
        XCTAssertFalse(state.mergeRefreshedItems([tab(0), window(20)]))
        XCTAssertEqual(state, previous)
    }

    func testReusedTabIndexDoesNotSelectDifferentTitle() {
        var state = SwitcherState(mode: .allAppsAndWindows, items: [tab(0), tab(1)], selectedIndex: 1)
        let different = SwitcherItem(app: app, kind: .window(WindowIdentity(
            windowID: 10, ownerProcessIdentifier: 1, title: "Different",
            tab: WindowTabIdentity(parentWindowID: 10, index: 1, title: "Different")
        )))
        XCTAssertFalse(state.mergeRefreshedItems([tab(0), different]))
        XCTAssertEqual(state.selectedItem?.title, "Tab 1")
    }

    func testSelectedTabKeepsItsTitleWhenIndexChanges() {
        var state = SwitcherState(mode: .allAppsAndWindows, items: [tab(0), tab(1)], selectedIndex: 1)
        let shifted = SwitcherItem(app: app, kind: .window(WindowIdentity(
            windowID: 10, ownerProcessIdentifier: 1, title: "Tab 1",
            tab: WindowTabIdentity(parentWindowID: 10, index: 0, title: "Tab 1")
        )))
        XCTAssertTrue(state.mergeRefreshedItems([shifted]))
        XCTAssertEqual(state.selectedItem?.title, "Tab 1")
        XCTAssertEqual(state.selectedItem?.id, shifted.id)
    }

    func testParentWithoutKnownSelectedTabIsNotRetargeted() {
        var state = SwitcherState(mode: .allAppsAndWindows, items: [window(10)])
        XCTAssertFalse(state.mergeRefreshedItems([tab(0), tab(1)]))
        XCTAssertEqual(state.selectedItem?.id, window(10).id)
    }

    func testDetailsForUnselectedParentCanExpandWhileSelectionStaysPut() {
        var state = SwitcherState(mode: .activeAppWindows, items: [window(10), window(20)], selectedIndex: 1)
        XCTAssertTrue(state.mergeRefreshedItems([tab(0), tab(1), window(20)]))
        XCTAssertEqual(state.selectedItem?.id, window(20).id)
        XCTAssertEqual(state.selectedIndex, 2)
    }
}
