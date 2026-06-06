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

    func testTitleFallbackUsesAppNameForUntitledWindow() {
        let app = AppIdentity(processIdentifier: 1, localizedName: "FallbackApp")
        let item = SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: 10, ownerProcessIdentifier: 1, title: "   ")))

        XCTAssertEqual(item.title, "FallbackApp")
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

    func testSwitchResultDistinguishesExactAndFallback() {
        XCTAssertNotEqual(SwitchResult.exactWindowSuccess, SwitchResult.limitedAppFallbackSuccess)
        XCTAssertEqual(SwitchResult.appActivationSuccess, .appActivationSuccess)
    }
}
