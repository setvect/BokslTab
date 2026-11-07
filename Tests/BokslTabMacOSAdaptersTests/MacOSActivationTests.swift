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
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: accessibility)
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
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { false }, accessibility: MacOSAccessibilityService(api: api))
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
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))
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
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))

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
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))

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
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api))
        let task = Task { await activator.activate(window: WindowIdentity(windowID: 42, ownerProcessIdentifier: 123), app: AppIdentity(processIdentifier: 123)) }
        await fulfillment(of: [started], timeout: 1)
        // This main-actor continuation runs while the AX worker is still blocked.
        task.cancel()
        release.signal()
        let result = await task.value
        guard case .safeFailure = result else { return XCTFail("Cancelled activation must not succeed") }
        XCTAssertTrue(recorder.intents.isEmpty)
    }

    /// Reported at 22:35: from the desktop, the full-screen Chrome window lives on a Space that AX does
    /// not list. The window server brings that window, and its Space, to the front.
    @MainActor
    func testWindowOnAnotherSpaceIsFocusedThroughTheWindowServer() async {
        let pid: Int32 = 999_645
        var api = currentSpaceAPI(windows: [(AXUIElementCreateApplication(999_151), 151)])
        var raised = 0
        api.performAction = { _, _ in raised += 1; return .success }
        let server = FakeWindowServer(placements: [689: (pid, false), 151: (pid, true)])
        let recorder = RecordingAppActivator()
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api), windowServer: server.access)

        let result = await activator.activate(
            window: WindowIdentity(windowID: 689, ownerProcessIdentifier: pid, title: "Video"),
            app: AppIdentity(processIdentifier: pid)
        )

        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertEqual(server.focusedWindowIDs, [689])
        XCTAssertTrue(recorder.intents.isEmpty)
        XCTAssertEqual(raised, 0)
    }

    @MainActor
    func testWindowServerFocusFailureFallsBackToAppActivation() async {
        let pid: Int32 = 999_645
        let api = currentSpaceAPI(windows: [(AXUIElementCreateApplication(999_151), 151)])
        let server = FakeWindowServer(placements: [689: (pid, false)], focusResult: .unavailable)
        let recorder = RecordingAppActivator()
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api), windowServer: server.access)

        let result = await activator.activate(
            window: WindowIdentity(windowID: 689, ownerProcessIdentifier: pid, title: "Video"),
            app: AppIdentity(processIdentifier: pid)
        )

        XCTAssertEqual(result, .limitedAppFallbackSuccess)
        XCTAssertEqual(server.focusedWindowIDs, [689])
        XCTAssertEqual(recorder.intents, [.focusOnly])
    }

    @MainActor
    func testWindowOnVisibleSpaceKeepsTheAccessibilityPath() async {
        let pid: Int32 = 999_645
        var api = currentSpaceAPI(windows: [(AXUIElementCreateApplication(999_151), 151)])
        var raised = 0
        api.performAction = { _, _ in raised += 1; return .success }
        let server = FakeWindowServer(placements: [151: (pid, true)])
        let recorder = RecordingAppActivator()
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api), windowServer: server.access)

        let result = await activator.activate(
            window: WindowIdentity(windowID: 151, ownerProcessIdentifier: pid, title: "Docs"),
            app: AppIdentity(processIdentifier: pid)
        )

        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertTrue(server.focusedWindowIDs.isEmpty)
        XCTAssertEqual(recorder.intents, [.focusOnly])
        XCTAssertEqual(raised, 1)
    }

    @MainActor
    func testMinimizedWindowIsRestoredAfterWindowServerFocus() async {
        let pid: Int32 = 999_645
        var api = currentSpaceAPI(windows: [(AXUIElementCreateApplication(999_152), 152)])
        var restored = false
        api.setAttribute = { _, attribute, value in
            if attribute as String == kAXMinimizedAttribute { restored = CFEqual(value, kCFBooleanFalse) }
            return .success
        }
        var raised = 0
        api.performAction = { _, _ in raised += 1; return .success }
        let server = FakeWindowServer(placements: [152: (pid, false)])
        let recorder = RecordingAppActivator()
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: MacOSAccessibilityService(api: api), windowServer: server.access)

        let result = await activator.activate(
            window: WindowIdentity(windowID: 152, ownerProcessIdentifier: pid, title: "Minimized"),
            app: AppIdentity(processIdentifier: pid)
        )

        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertEqual(server.focusedWindowIDs, [152])
        XCTAssertTrue(restored)
        XCTAssertEqual(raised, 1)
        XCTAssertTrue(recorder.intents.isEmpty)
    }

    /// Reported at 15:02: switching from the full-screen Chrome window to a desktop window was accepted by
    /// the window server, yet macOS stayed on the full-screen Space. The handle remembered while the target
    /// was visible is raised after the window-server focus, so the app brings the window forward itself.
    @MainActor
    func testRememberedHandleIsRaisedAfterWindowServerFocus() async {
        let pid: Int32 = 999_645
        let fullScreenWindow = AXUIElementCreateApplication(999_689)
        let desktopWindow = AXUIElementCreateApplication(999_151)
        var api = currentSpaceAPI(windows: [(fullScreenWindow, 689)], rememberedWindows: [(desktopWindow, 151)])
        var raised: [Int32] = []
        api.performAction = { element, action in
            if action as String == kAXRaiseAction { raised.append(Self.pid(of: element)) }
            return .success
        }
        let accessibility = MacOSAccessibilityService(api: api)
        accessibility.windowElements.record(desktopWindow, windowID: 151, processIdentifier: pid)
        let server = FakeWindowServer(placements: [151: (pid, false), 689: (pid, true)])
        let recorder = RecordingAppActivator()
        let activator = makeActivator(appActivator: recorder, isAccessibilityTrusted: { true }, accessibility: accessibility, windowServer: server.access)

        let result = await activator.activate(
            window: WindowIdentity(windowID: 151, ownerProcessIdentifier: pid, title: "Docs"),
            app: AppIdentity(processIdentifier: pid)
        )

        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertEqual(server.focusedWindowIDs, [151])
        XCTAssertEqual(raised, [999_151])
        XCTAssertTrue(recorder.intents.isEmpty)
        XCTAssertNotNil(accessibility.windowElements.element(windowID: 689, processIdentifier: pid), "current-Space handles are remembered too")
    }

    @MainActor
    func testStaleRememberedHandleIsDroppedAndOnlyTheWindowServerIsAsked() async {
        let pid: Int32 = 999_645
        let reusedHandle = AXUIElementCreateApplication(999_777)
        var api = currentSpaceAPI(windows: [], rememberedWindows: [(reusedHandle, 4242)])
        var raised = 0
        api.performAction = { _, _ in raised += 1; return .success }
        let accessibility = MacOSAccessibilityService(api: api)
        accessibility.windowElements.record(reusedHandle, windowID: 151, processIdentifier: pid)
        let server = FakeWindowServer(placements: [151: (pid, false)])
        let activator = makeActivator(appActivator: RecordingAppActivator(), isAccessibilityTrusted: { true }, accessibility: accessibility, windowServer: server.access)

        let result = await activator.activate(
            window: WindowIdentity(windowID: 151, ownerProcessIdentifier: pid, title: "Docs"),
            app: AppIdentity(processIdentifier: pid)
        )

        XCTAssertEqual(result, .exactWindowSuccess)
        XCTAssertEqual(server.focusedWindowIDs, [151])
        XCTAssertEqual(raised, 0)
        XCTAssertNil(accessibility.windowElements.element(windowID: 151, processIdentifier: pid))
    }

    func testPlacementReadsOwnerAndOnScreenFlag() {
        let owner = kCGWindowOwnerPID as String
        XCTAssertEqual(WindowServerPlacement(windowInfo: nil, processIdentifier: 1), .missing)
        XCTAssertEqual(WindowServerPlacement(windowInfo: [owner: NSNumber(value: 2)], processIdentifier: 1), .missing)
        XCTAssertEqual(WindowServerPlacement(windowInfo: [owner: NSNumber(value: 1)], processIdentifier: 1), .offScreen)
        XCTAssertEqual(
            WindowServerPlacement(
                windowInfo: [owner: NSNumber(value: 1), kCGWindowIsOnscreen as String: NSNumber(value: true)],
                processIdentifier: 1
            ),
            .onScreen
        )
    }

    func testMakeKeyWindowRecordsAddressTheWindow() {
        let records = WindowServerFocus.makeKeyWindowRecords(windowID: 0x0102_0304)

        XCTAssertEqual(records.count, 2)
        for (index, record) in records.enumerated() {
            XCTAssertEqual(record.count, 0xF8)
            XCTAssertEqual(record[0x04], 0xF8)
            XCTAssertEqual(record[0x08], UInt8(index + 1))
            XCTAssertEqual(record[0x3A], 0x10)
            XCTAssertEqual(Array(record[0x3C..<0x40]), [0x04, 0x03, 0x02, 0x01])
            XCTAssertEqual(Array(record[0x20..<0x30]), [UInt8](repeating: 0xFF, count: 0x10))
        }
    }

    /// AX of the current Space: lists only `windows`. Handles in `rememberedWindows` belong to windows on
    /// other Spaces: AX does not list them, but they still answer with their window number.
    private func currentSpaceAPI(
        windows: [(element: AXUIElement, windowID: UInt32)],
        rememberedWindows: [(element: AXUIElement, windowID: UInt32)] = []
    ) -> AccessibilityAPI {
        var api = testAccessibilityAPI()
        api.copyAttribute = { _, attribute, output in
            guard attribute as String == kAXWindowsAttribute else { return .attributeUnsupported }
            output.pointee = windows.map(\.element) as CFArray
            return .success
        }
        api.windowID = { element, windowID in
            guard let match = (windows + rememberedWindows).first(where: { CFEqual($0.element, element) }) else {
                return .failure
            }
            windowID.pointee = match.windowID
            return .success
        }
        return api
    }
}

/// Stands in for the window server: reports the given placements and records focus requests.
private final class FakeWindowServer {
    private let placements: [UInt32: (processIdentifier: Int32, onScreen: Bool)]
    private let focusResult: WindowServerFocusResult
    private(set) var focusedWindowIDs: [UInt32] = []

    init(placements: [UInt32: (processIdentifier: Int32, onScreen: Bool)], focusResult: WindowServerFocusResult = .focused) {
        self.placements = placements
        self.focusResult = focusResult
    }

    var access: WindowServerWindowAccess {
        WindowServerWindowAccess(
            windowInfo: { windowID in
                guard let placement = self.placements[windowID] else { return nil }
                var info: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: placement.processIdentifier)]
                if placement.onScreen { info[kCGWindowIsOnscreen as String] = NSNumber(value: true) }
                return info
            },
            focus: { windowID, _ in
                XCTAssertTrue(Thread.isMainThread)
                self.focusedWindowIDs.append(windowID)
                return self.focusResult
            }
        )
    }
}

/// Activators in tests never reach the real window server: a stray number could focus a real window.
func makeActivator(
    appActivator: AppActivating,
    isAccessibilityTrusted: @escaping () -> Bool,
    accessibility: MacOSAccessibilityService,
    windowServer: WindowServerWindowAccess = WindowServerWindowAccess(
        windowInfo: { _ in nil },
        focus: { _, _ in
            XCTFail("Window-server focus is only for windows it reports off screen")
            return .unavailable
        }
    )
) -> MacOSWindowActivator {
    MacOSWindowActivator(
        appActivator: appActivator,
        isAccessibilityTrusted: isAccessibilityTrusted,
        accessibility: accessibility,
        windowServer: windowServer
    )
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
