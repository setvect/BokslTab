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
}
