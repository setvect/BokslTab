import ApplicationServices
import BokslTabCore
@testable import BokslTabMacOSAdapters
import XCTest

final class MacOSActivationTests: XCTestCase {
    func testTabActivationPlanPreservesAlreadyMainParent() {
        XCTAssertEqual(AXTabActivationPlan.resolve(parentIsMain: true), .selectOnly)
        XCTAssertEqual(AXTabActivationPlan.resolve(parentIsMain: false), .focusParentThenSelect)
    }

    @MainActor
    func testUnresponsiveAppFallsBackAndSkipsSubsequentAXQueries() async {
        let app = AppIdentity(processIdentifier: 999_105, localizedName: "Unresponsive")
        let recorder = RecordingAppActivator()
        var reads = 0
        var api = testAccessibilityAPI()
        api.copyAttribute = { _, _, _ in
            XCTAssertFalse(Thread.isMainThread)
            reads += 1
            return .cannotComplete
        }
        let accessibility = MacOSAccessibilityService(api: api)
        let activator = MacOSWindowActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: accessibility)
        let window = WindowIdentity(windowID: 42, ownerProcessIdentifier: app.processIdentifier, title: "Target")
        let first = await activator.activate(window: window, app: app)
        let second = await activator.activate(window: window, app: app)
        XCTAssertEqual(first, .limitedAppFallbackSuccess)
        XCTAssertEqual(second, .limitedAppFallbackSuccess)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(recorder.intents, [.focusOnly, .focusOnly])
    }

    @MainActor
    func testDeniedPermissionDoesNotQueryAX() async {
        var api = testAccessibilityAPI()
        api.copyAttribute = { _, _, _ in XCTFail("Permission denied"); return .failure }
        let recorder = RecordingAppActivator()
        let activator = MacOSWindowActivator(appActivator: recorder, isAccessibilityTrusted: { false }, accessibility: MacOSAccessibilityService(api: api))
        let result = await activator.activate(window: WindowIdentity(windowID: 42, ownerProcessIdentifier: 123), app: AppIdentity(processIdentifier: 123))
        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertEqual(recorder.intents, [.focusOnly])
    }

    @MainActor
    func testDiscoveryAndActionsRunOffMainWithSeparateTimeouts() async {
        let element = AXUIElementCreateApplication(999_001)
        var api = testAccessibilityAPI()
        var timeouts: [Float] = []
        var actions: [String] = []
        api.setTimeout = { _, timeout in
            XCTAssertFalse(Thread.isMainThread)
            if timeout > 0 { timeouts.append(timeout) }
            return .success
        }
        api.copyAttribute = { _, attribute, output in
            XCTAssertFalse(Thread.isMainThread)
            switch attribute as String {
            case kAXWindowsAttribute: output.pointee = [element] as CFArray
            case kAXTitleAttribute: output.pointee = "Target" as CFString
            default: return .attributeUnsupported
            }
            return .success
        }
        api.performAction = { _, action in
            XCTAssertFalse(Thread.isMainThread)
            actions.append(action as String)
            return .success
        }
        let recorder = RecordingAppActivator()
        let activator = MacOSWindowActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))
        let result = await activator.activate(window: WindowIdentity(windowID: 42, ownerProcessIdentifier: 123, title: "Target"), app: AppIdentity(processIdentifier: 123))
        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertEqual(actions, [kAXRaiseAction])
        XCTAssertTrue(timeouts.prefix(2).allSatisfy { $0 > 0 && $0 <= 0.08 })
        XCTAssertTrue(timeouts.dropFirst(2).allSatisfy { $0 > 0 && $0 <= 0.25 })
        XCTAssertEqual(recorder.intents, [.focusOnly])
    }

    @MainActor
    func testCancelledDiscoveryCannotStealFocusWhenItEventuallyReturns() async {
        let started = expectation(description: "AX lookup started")
        let release = DispatchSemaphore(value: 0)
        var api = testAccessibilityAPI()
        api.copyAttribute = { _, _, _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return .attributeUnsupported
        }
        let recorder = RecordingAppActivator()
        let activator = MacOSWindowActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))
        let task = Task { await activator.activate(window: WindowIdentity(windowID: 42, ownerProcessIdentifier: 123), app: AppIdentity(processIdentifier: 123)) }
        await fulfillment(of: [started], timeout: 1)
        // This main-actor continuation runs while the AX worker is still blocked.
        task.cancel()
        release.signal()
        let result = await task.value
        guard case .safeFailure = result else { return XCTFail("Cancelled activation must not succeed") }
        XCTAssertTrue(recorder.intents.isEmpty)
    }
}

private final class RecordingAppActivator: AppActivating {
    private(set) var intents: [AppActivationIntent] = []
    func activate(app: AppIdentity, intent: AppActivationIntent) -> SwitchResult {
        XCTAssertTrue(Thread.isMainThread)
        intents.append(intent)
        return .appActivationSuccess
    }
}

func testAccessibilityAPI() -> AccessibilityAPI {
    AccessibilityAPI(
        setTimeout: { _, _ in .success },
        copyAttribute: { _, _, _ in .attributeUnsupported },
        setAttribute: { _, _, _ in .success },
        performAction: { _, _ in .success }
    )
}
