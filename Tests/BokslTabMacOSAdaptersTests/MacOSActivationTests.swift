import BokslTabCore
@testable import BokslTabMacOSAdapters
import XCTest

final class MacOSActivationTests: XCTestCase {
    func testWindowFallbackReopensAppWhenTargetWindowCannotBeMatched() {
        let app = AppIdentity(
            processIdentifier: 41546,
            bundleIdentifier: "com.apple.iCal",
            localizedName: "캘린더",
            processName: "Calendar"
        )
        let closedWindow = WindowIdentity(
            windowID: 1_952_339_200,
            ownerProcessIdentifier: app.processIdentifier,
            title: "캘린더"
        )
        let appActivator = RecordingReopeningAppActivator(result: .appActivationSuccess)
        let windowActivator = MacOSWindowActivator(
            appActivator: appActivator,
            isAccessibilityTrusted: { false }
        )

        let result = windowActivator.activate(window: closedWindow, app: app)

        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertEqual(appActivator.reopenedApps, [app])
        XCTAssertTrue(appActivator.activatedApps.isEmpty)
    }
}

private final class RecordingReopeningAppActivator: AppActivating, AppReopening {
    private let result: SwitchResult
    private(set) var activatedApps: [AppIdentity] = []
    private(set) var reopenedApps: [AppIdentity] = []

    init(result: SwitchResult) {
        self.result = result
    }

    func activate(app: AppIdentity) -> SwitchResult {
        activatedApps.append(app)
        return result
    }

    func reopen(app: AppIdentity) -> SwitchResult {
        reopenedApps.append(app)
        return result
    }
}
