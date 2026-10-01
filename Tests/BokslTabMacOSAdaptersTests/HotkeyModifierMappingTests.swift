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
        let definition = SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
        let error = HotkeyRegistrationError.registrationFailed(definition: definition, code: -9878)

        XCTAssertEqual(definition.description, "mode=allAppsAndWindows, hotkey=Cmd+keyCode(48)")
        XCTAssertTrue(error.description.contains("allAppsAndWindows"))
        XCTAssertTrue(error.description.contains("-9878"))
    }

    func testDefaultHotkeyDefinitionsAreModeSpecific() {
        XCTAssertEqual(SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition.modifiers, [.command])
        XCTAssertEqual(SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition.keyCode, 48)
        XCTAssertEqual(SwitcherMode.activeAppWindows.defaultHotkeyDefinition.modifiers, [.option])
        XCTAssertEqual(SwitcherMode.activeAppWindows.defaultHotkeyDefinition.keyCode, 48)
    }

    func testPartialHotkeyDiagnosticIncludesEachFailedDefinition() {
        let failure = HotkeyRegistrationFailure(
            definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition,
            code: -9878
        )
        let error = HotkeyRegistrationError.partialRegistrationFailed(failures: [failure])

        XCTAssertTrue(error.description.contains("partialRegistrationFailed"))
        XCTAssertTrue(error.description.contains("Cmd+keyCode(48)"))
        XCTAssertTrue(error.description.contains("-9878"))
    }

    func testCommandTabEventTapUsesHIDLocationForSystemShortcutPriority() {
        XCTAssertEqual(CommandTabEventTapConfiguration.location, .cghidEventTap)
        XCTAssertEqual(CommandTabEventTapConfiguration.locationDescription, "cghidEventTap")
    }

    func testCommandTabEventTapMatcherCapturesOnlyConfiguredCommandTab() {
        XCTAssertTrue(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand],
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertTrue(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand, .maskShift],
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskAlternate],
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 49,
                flags: [.maskCommand],
                definition: SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand],
                definition: SwitcherMode.activeAppWindows.defaultHotkeyDefinition
            )
        )
    }

    func testCommandTabEventTapSuppressesSystemAutoRepeatWithoutNotifyingTrigger() {
        let definition = SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition

        XCTAssertTrue(
            CommandTabEventTapMatcher.shouldNotifyTrigger(
                keyCode: 48,
                flags: [.maskCommand],
                definition: definition,
                isAutoRepeat: false
            )
        )
        XCTAssertFalse(
            CommandTabEventTapMatcher.shouldNotifyTrigger(
                keyCode: 48,
                flags: [.maskCommand],
                definition: definition,
                isAutoRepeat: true
            )
        )
        XCTAssertTrue(
            CommandTabEventTapMatcher.shouldCapture(
                keyCode: 48,
                flags: [.maskCommand],
                definition: definition
            )
        )
    }

}
