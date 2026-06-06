import BokslTabCore
@testable import BokslTabMacOSAdapters
import Carbon
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
}
