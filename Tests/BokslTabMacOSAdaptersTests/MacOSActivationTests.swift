import BokslTabCore
@testable import BokslTabMacOSAdapters
import XCTest

final class MacOSActivationTests: XCTestCase {
    func testTabActivationSelectsOnlyWhenParentIsAlreadyMain() {
        XCTAssertEqual(AXTabActivationPlan.resolve(parentIsMain: true), .selectOnly)
    }

    func testTabActivationFocusesParentBeforeSelectionWhenAnotherWindowIsMain() {
        XCTAssertEqual(AXTabActivationPlan.resolve(parentIsMain: false), .focusParentThenSelect)
    }

    func testCachedWindowFallbackReopensAppWhenTargetWindowCannotBeMatched() {
        let app = AppIdentity(
            processIdentifier: 999_001,
            bundleIdentifier: "com.apple.iCal",
            localizedName: "캘린더",
            processName: "Calendar"
        )
        let closedWindow = WindowIdentity(
            windowID: SyntheticWindowID.cached(
                processIdentifier: app.processIdentifier,
                title: "캘린더",
                frame: .init(x: 0, y: 0, width: 800, height: 600),
                index: 0
            ),
            ownerProcessIdentifier: app.processIdentifier,
            title: "캘린더",
            source: .cached
        )
        let appActivator = RecordingAppActivator(result: .appActivationSuccess)
        let windowActivator = MacOSWindowActivator(
            appActivator: appActivator,
            isAccessibilityTrusted: { true }
        )

        let result = windowActivator.activate(window: closedWindow, app: app)

        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertEqual(appActivator.activations.map(\.app), [app])
        XCTAssertEqual(appActivator.activations.map(\.intent), [.reopenIfNeeded])
    }

    func testAccessibilityDeniedFallbackOnlyFocusesApp() {
        let app = AppIdentity(processIdentifier: 999_002, localizedName: "테스트 앱")
        let window = WindowIdentity(
            windowID: 42,
            ownerProcessIdentifier: app.processIdentifier,
            title: "테스트 창"
        )
        let appActivator = RecordingAppActivator(result: .appActivationSuccess)
        let windowActivator = MacOSWindowActivator(
            appActivator: appActivator,
            isAccessibilityTrusted: { false }
        )

        let result = windowActivator.activate(window: window, app: app)

        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertEqual(appActivator.activations.map(\.app), [app])
        XCTAssertEqual(appActivator.activations.map(\.intent), [.focusOnly])
    }

    func testNativeHighBitWindowIDFallbackOnlyFocusesApp() {
        let app = AppIdentity(processIdentifier: 999_003, localizedName: "테스트 앱")
        let nativeWindow = WindowIdentity(
            windowID: 0x4000_0001,
            ownerProcessIdentifier: app.processIdentifier,
            title: "네이티브 창"
        )
        let appActivator = RecordingAppActivator(result: .appActivationSuccess)
        let windowActivator = MacOSWindowActivator(
            appActivator: appActivator,
            isAccessibilityTrusted: { true }
        )

        let result = windowActivator.activate(window: nativeWindow, app: app)

        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertEqual(appActivator.activations.map(\.app), [app])
        XCTAssertEqual(appActivator.activations.map(\.intent), [.focusOnly])
    }
}

private final class RecordingAppActivator: AppActivating {
    struct Activation: Equatable {
        let app: AppIdentity
        let intent: AppActivationIntent
    }

    private let result: SwitchResult
    private(set) var activations: [Activation] = []

    init(result: SwitchResult) {
        self.result = result
    }

    func activate(app: AppIdentity, intent: AppActivationIntent) -> SwitchResult {
        activations.append(Activation(app: app, intent: intent))
        return result
    }
}
