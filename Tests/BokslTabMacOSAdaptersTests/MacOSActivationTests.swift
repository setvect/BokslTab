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
        // Discovery: windows, window number, title. Actions: main, focused, raise.
        XCTAssertEqual(timeouts.count, 6)
        XCTAssertTrue(timeouts.prefix(3).allSatisfy { $0 > 0 && $0 <= 0.08 })
        XCTAssertTrue(timeouts.dropFirst(3).allSatisfy { $0 > 0.08 && $0 <= 0.25 })
        XCTAssertEqual(recorder.intents, [.focusOnly])
    }

    /// Reported at 21:14: the row for Code#95 carried #97's title, and raising by title brought #97 forward.
    @MainActor
    func testActivationRaisesTheRowsWindowNumberEvenWhenItsTitleBelongsToASibling() async {
        let window95 = AXUIElementCreateApplication(999_295)
        let window97 = AXUIElementCreateApplication(999_297)
        var api = siblingWindowsAPI(window97: window97, window95: window95)
        var raised: [Int32] = []
        api.performAction = { element, action in
            if action as String == kAXRaiseAction { raised.append(Self.pid(of: element)) }
            return .success
        }
        let recorder = RecordingAppActivator()
        let activator = MacOSWindowActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))

        let result = await activator.activate(
            window: WindowIdentity(windowID: 95, ownerProcessIdentifier: 661, title: "Alpha — BokslTab"),
            app: AppIdentity(processIdentifier: 661)
        )

        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertEqual(raised, [999_295])
    }

    @MainActor
    func testActivationDoesNotBorrowAnIdentifiedSiblingByTitleWhenTheWindowIsGone() async {
        let window95 = AXUIElementCreateApplication(999_295)
        let window97 = AXUIElementCreateApplication(999_297)
        var api = siblingWindowsAPI(window97: window97, window95: window95)
        var raised: [Int32] = []
        api.performAction = { element, action in
            if action as String == kAXRaiseAction { raised.append(Self.pid(of: element)) }
            return .success
        }
        let recorder = RecordingAppActivator()
        let activator = MacOSWindowActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))

        let result = await activator.activate(
            window: WindowIdentity(windowID: 42, ownerProcessIdentifier: 661, title: "Alpha — BokslTab"),
            app: AppIdentity(processIdentifier: 661)
        )

        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertTrue(raised.isEmpty)
        XCTAssertEqual(recorder.intents, [.focusOnly])
    }

    /// Two maximized windows of one app, listed front to back: #97 "Alpha", then #95 "Zeta".
    private func siblingWindowsAPI(window97: AXUIElement, window95: AXUIElement) -> AccessibilityAPI {
        var api = testAccessibilityAPI()
        api.copyAttribute = { element, attribute, output in
            switch attribute as String {
            case kAXWindowsAttribute: output.pointee = [window97, window95] as CFArray
            case kAXTitleAttribute: output.pointee = (Self.pid(of: element) == 999_297 ? "Alpha — BokslTab" : "Zeta — BokslDir") as CFString
            default: return .attributeUnsupported
            }
            return .success
        }
        api.windowID = { element, windowID in
            windowID.pointee = Self.pid(of: element) == 999_297 ? 97 : 95
            return .success
        }
        return api
    }

    private static func pid(of element: AXUIElement) -> Int32 {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return pid
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
