import BokslTabCore
@testable import BokslTabMacOSAdapters
import Carbon
import CoreGraphics
import XCTest

final class HotkeyModifierMappingTests: XCTestCase {
    func testCarbonFlagsMapCoreModifiers() {
        let modifiers: HotkeyModifiers = [.command, .option, .control, .shift]

        XCTAssertTrue(modifiers.carbonFlags & UInt32(cmdKey) != 0)
        XCTAssertTrue(modifiers.carbonFlags & UInt32(optionKey) != 0)
        XCTAssertTrue(modifiers.carbonFlags & UInt32(controlKey) != 0)
        XCTAssertTrue(modifiers.carbonFlags & UInt32(shiftKey) != 0)
    }

    func testEmptyCarbonFlagsAreZero() {
        XCTAssertEqual(HotkeyModifiers().carbonFlags, 0)
    }

    func testHotkeyDiagnosticDescriptionsIncludeModeAndCode() {
        let definition = SwitcherMode.activeAppWindows.defaultHotkeyDefinition
        let error = HotkeyRegistrationError.registrationFailed(definition: definition, code: -9878)

        XCTAssertEqual(definition.description, "mode=activeAppWindows, hotkey=Cmd+keyCode(48)")
        XCTAssertTrue(error.description.contains("activeAppWindows"))
        XCTAssertTrue(error.description.contains("-9878"))
    }

    func testDefaultHotkeyDefinitionsAreModeSpecific() {
        XCTAssertEqual(SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition.modifiers, [.option])
        XCTAssertEqual(SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition.keyCode, 48)
        XCTAssertEqual(SwitcherMode.activeAppWindows.defaultHotkeyDefinition.modifiers, [.command])
        XCTAssertEqual(SwitcherMode.activeAppWindows.defaultHotkeyDefinition.keyCode, 48)
    }

    func testPartialHotkeyDiagnosticIncludesEachFailedDefinition() {
        let failure = HotkeyRegistrationFailure(
            definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition,
            code: -9878
        )
        let error = HotkeyRegistrationError.partialRegistrationFailed(failures: [failure])

        XCTAssertTrue(error.description.contains("partialRegistrationFailed"))
        XCTAssertTrue(error.description.contains("Cmd+keyCode(48)"))
        XCTAssertTrue(error.description.contains("-9878"))
    }

    func testCommandTabEventTapMatcherCapturesOnlyActiveAppCommandTab() {
        XCTAssertTrue(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand],
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertTrue(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand, .maskShift],
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskAlternate],
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 49,
                flags: [.maskCommand],
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand],
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
            )
        )
    }

    func testPrioritizedHotkeyPlanRemovesCommandTabFromCarbonWhenEventTapIsAvailable() {
        let definitions = [
            SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition,
            SwitcherMode.activeAppWindows.defaultHotkeyDefinition
        ]
        let plan = PrioritizedHotkeyPlan.make(definitions: definitions)

        XCTAssertEqual(plan.eventTapDefinition, SwitcherMode.activeAppWindows.defaultHotkeyDefinition)
        XCTAssertEqual(plan.carbonDefinitionsWhenEventTapSucceeds, [SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition])
    }

    func testPrioritizedServiceUsesCarbonFallbackWithoutCommandTabWhenEventTapSucceeds() throws {
        let eventTapService = FakeCommandTabEventTapHotkeyService()
        let fallbackService = FakeGlobalHotkeyService()
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService
        )

        try service.start(definitions: defaultDefinitions) { _ in }

        XCTAssertEqual(eventTapService.startedDefinitions, [SwitcherMode.activeAppWindows.defaultHotkeyDefinition])
        XCTAssertEqual(fallbackService.startedDefinitions, [SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition])
    }

    func testPrioritizedServiceFallsBackToAllCarbonDefinitionsWhenEventTapFails() throws {
        let eventTapService = FakeCommandTabEventTapHotkeyService(
            startError: HotkeyRegistrationError.registrationFailed(
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition,
                code: -10_001
            )
        )
        let fallbackService = FakeGlobalHotkeyService()
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService
        )

        try service.start(definitions: defaultDefinitions) { _ in }

        XCTAssertEqual(eventTapService.startedDefinitions, [SwitcherMode.activeAppWindows.defaultHotkeyDefinition])
        XCTAssertTrue(eventTapService.didStop)
        XCTAssertEqual(fallbackService.startedDefinitions, defaultDefinitions)
    }

    func testPrioritizedServiceStopsEventTapWhenCarbonFallbackFails() {
        let eventTapService = FakeCommandTabEventTapHotkeyService()
        let fallbackService = FakeGlobalHotkeyService(
            startError: HotkeyRegistrationError.registrationFailed(
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition,
                code: -9878
            )
        )
        let service = PrioritizedGlobalHotkeyService(
            commandTabEventTapService: eventTapService,
            fallbackHotkeyService: fallbackService
        )

        XCTAssertThrowsError(try service.start(definitions: defaultDefinitions) { _ in })
        XCTAssertTrue(eventTapService.didStop)
        XCTAssertTrue(fallbackService.didStop)
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

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(
        definition: HotkeyDefinition,
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) throws {
        startedDefinitions.append(definition)
        if let startError {
            throw startError
        }
    }

    func stop() {
        didStop = true
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
