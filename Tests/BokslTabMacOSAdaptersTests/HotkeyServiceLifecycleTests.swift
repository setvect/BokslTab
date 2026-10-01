import BokslTabCore
@testable import BokslTabMacOSAdapters
import Carbon
import CoreGraphics
import XCTest

final class HotkeyServiceLifecycleTests: XCTestCase {
    func testPrioritizedHotkeyPlanRemovesCommandTabFromCarbonWhenEventTapIsAvailable() {
        let definitions = [
            SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition,
            SwitcherMode.activeAppWindows.defaultHotkeyDefinition
        ]
        let plan = PrioritizedHotkeyPlan.make(definitions: definitions)

        XCTAssertEqual(plan.eventTapDefinition, SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition)
        XCTAssertEqual(plan.carbonDefinitionsWhenEventTapSucceeds, [SwitcherMode.activeAppWindows.defaultHotkeyDefinition])
        XCTAssertTrue(plan.requiresNativeCommandTabOverride)
    }

    func testNativeCommandTabSymbolicHotKeyIDsMatchMacOSSwitcherIDs() {
        XCTAssertEqual(NativeCommandTabSymbolicHotKey.allCases.map(\.rawValue), [1, 2])
    }

    func testNativeCommandTabServiceRestoresCapturedStates() {
        FakeSkyLightState.reset(enabledStates: [1: true, 2: false])
        let service = NativeCommandTabHotkeyService(loader: FakeSkyLightSymbolLoader())

        XCTAssertTrue(service.disableCommandTabPair())
        XCTAssertEqual(FakeSkyLightState.enabledStates, [1: false, 2: false])

        service.restore()

        XCTAssertEqual(FakeSkyLightState.enabledStates, [1: true, 2: false])
    }

    func testNativeCommandTabServiceRollsBackWhenDisableFails() {
        FakeSkyLightState.reset(enabledStates: [1: true, 2: true], failingDisableIDs: [2])
        let service = NativeCommandTabHotkeyService(loader: FakeSkyLightSymbolLoader())

        XCTAssertFalse(service.disableCommandTabPair())

        XCTAssertEqual(FakeSkyLightState.enabledStates, [1: true, 2: true])
    }

    func testNativeCommandTabRecoveryEnablesBothHotkeys() {
        FakeSkyLightState.reset(enabledStates: [1: false, 2: false])

        XCTAssertTrue(NativeCommandTabHotkeyRecovery.enableCommandTabPair(loader: FakeSkyLightSymbolLoader()))

        XCTAssertEqual(FakeSkyLightState.enabledStates, [1: true, 2: true])
    }

    func testPrioritizedServiceUsesCarbonForCommandTabWhenNativeOverrideSucceeds() throws {
        let eventTapService = FakeCommandTabEventTapHotkeyService()
        let fallbackService = FakeGlobalHotkeyService()
        let nativeHotkeyService = FakeNativeCommandTabHotkeyService()
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService,
            nativeCommandTabHotkeyService: nativeHotkeyService
        )

        try service.start(definitions: defaultDefinitions) { _ in }

        XCTAssertEqual(nativeHotkeyService.disableCallCount, 1)
        XCTAssertEqual(eventTapService.startedDefinitions, [])
        XCTAssertEqual(fallbackService.startedDefinitions, defaultDefinitions)
    }

    func testPrioritizedServiceFallsBackToAllCarbonDefinitionsWhenNativeAndEventTapFail() throws {
        let eventTapService = FakeCommandTabEventTapHotkeyService(
            startError: HotkeyRegistrationError.registrationFailed(
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition,
                code: -10_001
            )
        )
        let fallbackService = FakeGlobalHotkeyService()
        let nativeHotkeyService = FakeNativeCommandTabHotkeyService()
        nativeHotkeyService.disableResult = false
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService,
            nativeCommandTabHotkeyService: nativeHotkeyService
        )

        try service.start(definitions: defaultDefinitions) { _ in }

        XCTAssertEqual(nativeHotkeyService.disableCallCount, 1)
        XCTAssertEqual(eventTapService.startedDefinitions, [SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition])
        XCTAssertTrue(eventTapService.didStop)
        XCTAssertEqual(fallbackService.startedDefinitions, defaultDefinitions)
    }

    func testPrioritizedServiceStopsEventTapWhenCarbonFallbackFails() {
        let eventTapService = FakeCommandTabEventTapHotkeyService()
        let fallbackService = FakeGlobalHotkeyService(
            startError: HotkeyRegistrationError.registrationFailed(
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition,
                code: -9878
            )
        )
        let nativeHotkeyService = FakeNativeCommandTabHotkeyService()
        nativeHotkeyService.disableResult = false
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService,
            nativeCommandTabHotkeyService: nativeHotkeyService
        )

        XCTAssertThrowsError(try service.start(definitions: defaultDefinitions) { _ in })
        XCTAssertEqual(nativeHotkeyService.disableCallCount, 1)
        XCTAssertEqual(nativeHotkeyService.restoreCallCount, 0)
        XCTAssertEqual(eventTapService.startedDefinitions, [SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition])
        XCTAssertFalse(eventTapService.isActive)
        XCTAssertTrue(eventTapService.didStop)
        XCTAssertTrue(fallbackService.didStop)
    }

    func testPrioritizedServiceDoesNotDisableNativeCommandTabWithoutCommandTabDefinition() throws {
        let eventTapService = FakeCommandTabEventTapHotkeyService()
        let fallbackService = FakeGlobalHotkeyService()
        let nativeHotkeyService = FakeNativeCommandTabHotkeyService()
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService,
            nativeCommandTabHotkeyService: nativeHotkeyService
        )

        try service.start(definitions: [SwitcherMode.activeAppWindows.defaultHotkeyDefinition]) { _ in }

        XCTAssertEqual(nativeHotkeyService.disableCallCount, 0)
        XCTAssertEqual(eventTapService.startedDefinitions, [])
        XCTAssertEqual(fallbackService.startedDefinitions, [SwitcherMode.activeAppWindows.defaultHotkeyDefinition])
    }

    private var defaultDefinitions: [HotkeyDefinition] {
        [
            SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition,
            SwitcherMode.activeAppWindows.defaultHotkeyDefinition
        ]
    }
}

private final class FakeCommandTabEventTapHotkeyService: CommandTabEventTapHotkeyServicing {
    private let startError: Error?
    private(set) var startedDefinitions: [HotkeyDefinition] = []
    private(set) var didStop = false
    private(set) var isActive = false

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(
        definition: HotkeyDefinition,
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) throws {
        startedDefinitions.append(definition)
        isActive = true
        if let startError {
            throw startError
        }
    }

    func stop() {
        didStop = true
        isActive = false
    }
}

private final class FakeGlobalHotkeyService: GlobalHotkeyServicing {
    private let startError: Error?
    private(set) var startedDefinitions: [HotkeyDefinition] = []
    private(set) var didStop = false

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(
        definitions: [HotkeyDefinition],
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) throws {
        startedDefinitions = definitions
        if let startError {
            throw startError
        }
    }

    func stop() {
        didStop = true
    }
}

private final class FakeNativeCommandTabHotkeyService: NativeCommandTabHotkeyServicing {
    private(set) var disableCallCount = 0
    private(set) var restoreCallCount = 0
    var disableResult = true
    private var active = false

    func disableCommandTabPair() -> Bool {
        disableCallCount += 1
        active = disableResult
        return disableResult
    }

    func restore() {
        guard active else { return }
        restoreCallCount += 1
        active = false
    }
}

private enum FakeSkyLightState {
    static var enabledStates: [Int: Bool] = [:]
    static var failingDisableIDs: Set<Int> = []
    static var setCalls: [(id: Int, enabled: Bool)] = []

    static func reset(enabledStates: [Int: Bool], failingDisableIDs: Set<Int> = []) {
        self.enabledStates = enabledStates
        self.failingDisableIDs = failingDisableIDs
        self.setCalls = []
    }
}

private struct FakeSkyLightSymbolLoader: SkyLightSymbolLoading {
    func load() -> SkyLightSymbolTable? {
        SkyLightSymbolTable(
            setEnabled: fakeSetSymbolicHotKeyEnabled,
            isEnabled: fakeIsSymbolicHotKeyEnabled
        )
    }
}

private func fakeSetSymbolicHotKeyEnabled(_ id: Int, _ enabled: Bool) -> Int32 {
    FakeSkyLightState.setCalls.append((id: id, enabled: enabled))
    if !enabled, FakeSkyLightState.failingDisableIDs.contains(id) {
        return -1
    }

    FakeSkyLightState.enabledStates[id] = enabled
    return 0
}

private func fakeIsSymbolicHotKeyEnabled(_ id: Int) -> Bool {
    FakeSkyLightState.enabledStates[id, default: false]
}
