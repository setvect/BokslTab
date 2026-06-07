import XCTest
@testable import BokslTabCore

final class SwitcherStateTests: XCTestCase {
    func testSelectionWrapsForwardAndBackward() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let items = [
            SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "A"))),
            SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 11, ownerProcessIdentifier: 1, title: "B")))
        ]
        var state = SwitcherState(mode: .allAppsAndWindows, items: items)

        XCTAssertEqual(state.selectedItem?.title, "A")
        state.moveNext()
        XCTAssertEqual(state.selectedItem?.title, "B")
        state.moveNext()
        XCTAssertEqual(state.selectedItem?.title, "A")
        state.movePrevious()
        XCTAssertEqual(state.selectedItem?.title, "B")
    }


    func testSelectClampsToAvailableItems() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let items = [
            SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "A"))),
            SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 11, ownerProcessIdentifier: 1, title: "B")))
        ]
        var state = SwitcherState(mode: .allAppsAndWindows, items: items)

        state.select(index: 99)
        XCTAssertEqual(state.selectedIndex, 1)

        state.select(index: -1)
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testTitleFallbackDistinguishesUntitledWindows() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "FallbackApp")
        let item = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "   ")))

        XCTAssertEqual(item.title, "FallbackApp 창 10")
        XCTAssertEqual(item.subtitle, "FallbackApp")
    }

    func testAllAppsAndWindowsComposesWindowsAndAppFallbacks() {
        let code = AppIdentity(processIdentifier: 1, localizedName: "Code")
        let notes = AppIdentity(processIdentifier: 2, localizedName: "Notes")
        let windows = [WindowIdentity(windowID: 100, ownerProcessIdentifier: 1, title: "Project")]

        let items = SwitcherItemComposer.composeAllAppsAndWindows(apps: [code, notes], windows: windows)

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.title == "Project" && $0.isWindow })
        XCTAssertTrue(items.contains { $0.title == "Notes" && !$0.isWindow })
    }

    func testActiveAppWindowsShowsSingleAppRowWhenNoWindows() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "Solo")

        let items = SwitcherItemComposer.composeActiveAppWindows(app: app, windows: [])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Solo")
        XCTAssertFalse(items.first?.isWindow ?? true)
    }

    func testWindowItemProjectsWindowAndAppIDsForMRU() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let item = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "Window")))

        XCTAssertEqual(item.mruProjectedIDs, ["window:10:1", "app:1"])
    }

    func testMRUOrderingSelectsPreviousWindowBeforeCurrentWindow() {
        let chrome = AppIdentity(processIdentifier: 1, localizedName: "Chrome")
        let code = AppIdentity(processIdentifier: 2, localizedName: "Code")
        let terminal = AppIdentity(processIdentifier: 3, localizedName: "Terminal")
        let current = SwitcherItem(app: terminal, kind: .window(WindowIdentity(windowID: 30, ownerProcessIdentifier: 3, title: "Terminal")))
        let previous = SwitcherItem(app: code, kind: .window(WindowIdentity(windowID: 20, ownerProcessIdentifier: 2, title: "Project")))
        let older = SwitcherItem(app: chrome, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "Docs")))
        let items = [older, current, previous]

        let ordered = SwitcherMRUOrderer.order(
            items: items,
            context: SwitcherMRUOrderingContext(
                orderedItemIDs: [current.id, previous.id, older.id],
                currentItemID: current.id,
                sourceDescription: "test"
            )
        )

        XCTAssertEqual(ordered.map(\.id), [previous.id, older.id, current.id])
    }

    func testMRUOrderingWorksForActiveAppWindows() {
        let browser = AppIdentity(processIdentifier: 1, localizedName: "Browser")
        let current = SwitcherItem(app: browser, kind: .window(WindowIdentity(windowID: 30, ownerProcessIdentifier: 1, title: "Current")))
        let previous = SwitcherItem(app: browser, kind: .window(WindowIdentity(windowID: 20, ownerProcessIdentifier: 1, title: "Previous")))
        let older = SwitcherItem(app: browser, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "Older")))

        let ordered = SwitcherMRUOrderer.order(
            items: [older, previous, current],
            context: SwitcherMRUOrderingContext(
                orderedItemIDs: [current.id, previous.id, older.id],
                currentItemID: current.id,
                sourceDescription: "test"
            )
        )

        XCTAssertEqual(ordered.map(\.title), ["Previous", "Older", "Current"])
    }

    func testMRUOrderingFallsBackToTitleSortWithoutMRUInformation() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let beta = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 2, ownerProcessIdentifier: 1, title: "Beta")))
        let alpha = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "Alpha")))

        let ordered = SwitcherMRUOrderer.order(
            items: [beta, alpha],
            context: .fallback(reason: "test")
        )

        XCTAssertEqual(ordered.map(\.title), ["Alpha", "Beta"])
    }

    func testMRUOrderingPlacesUnknownItemsAfterKnownItemsByTitle() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let known = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 2, ownerProcessIdentifier: 1, title: "Known")))
        let beta = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 3, ownerProcessIdentifier: 1, title: "Beta")))
        let alpha = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "Alpha")))

        let ordered = SwitcherMRUOrderer.order(
            items: [beta, known, alpha],
            context: SwitcherMRUOrderingContext(
                orderedItemIDs: [known.id],
                currentItemID: nil,
                sourceDescription: "test"
            )
        )

        XCTAssertEqual(ordered.map(\.title), ["Known", "Alpha", "Beta"])
    }

    func testMRUOrderingKeepsGivenOrderWhenCurrentItemIsNotMatched() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let first = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "First")))
        let second = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 2, ownerProcessIdentifier: 1, title: "Second")))

        let ordered = SwitcherMRUOrderer.order(
            items: [second, first],
            context: SwitcherMRUOrderingContext(
                orderedItemIDs: [second.id, first.id],
                currentItemID: "window:999:999",
                sourceDescription: "test"
            )
        )

        XCTAssertEqual(ordered.map(\.title), ["Second", "First"])
    }

    func testMRUOrderingDoesNotDropDuplicateItemIDs() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let first = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "First")))
        let duplicate = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "Duplicate")))

        let ordered = SwitcherMRUOrderer.order(
            items: [duplicate, first],
            context: SwitcherMRUOrderingContext(
                orderedItemIDs: [first.id],
                currentItemID: nil,
                sourceDescription: "test"
            )
        )

        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(Set(ordered.map(\.title)), Set(["Duplicate", "First"]))
    }

    func testMRUDiagnosticsReportsPartialTitleSortFallback() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let known = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "Known")))
        let unknown = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 2, ownerProcessIdentifier: 1, title: "Unknown")))

        let diagnostics = SwitcherMRUOrderer.diagnostics(
            items: [known, unknown],
            context: SwitcherMRUOrderingContext(
                orderedItemIDs: [known.id],
                currentItemID: nil,
                sourceDescription: "test"
            )
        )

        XCTAssertEqual(diagnostics.matchedItemCount, 1)
        XCTAssertEqual(diagnostics.unmatchedItemCount, 1)
        XCTAssertEqual(diagnostics.partialFallbackReason, "title-sort-unmatched-items")
    }

    func testMRUDiagnosticsDoesNotReportPartialFallbackForFullFallbackContext() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "App")
        let item = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 1, ownerProcessIdentifier: 1, title: "Item")))

        let diagnostics = SwitcherMRUOrderer.diagnostics(
            items: [item],
            context: .fallback(reason: "test")
        )

        XCTAssertEqual(diagnostics.matchedItemCount, 0)
        XCTAssertEqual(diagnostics.unmatchedItemCount, 1)
        XCTAssertNil(diagnostics.partialFallbackReason)
    }

    func testSwitchResultDistinguishesExactAndFallback() {
        XCTAssertNotEqual(SwitchResult.exactWindowSuccess, SwitchResult.limitedAppFallbackSuccess)
        XCTAssertEqual(SwitchResult.appActivationSuccess, .appActivationSuccess)
    }
}
