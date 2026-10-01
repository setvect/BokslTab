import AppKit
@testable import BokslTabUI
import XCTest

final class SwitcherKeyboardMapperTests: XCTestCase {
    func testNavigationKeysMapToNextAndPrevious() {
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 48)), .next)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 48, modifiers: [.shift])), .previous)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 125)), .next)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 126)), .previous)
    }

    func testConfirmCancelAndOptionModifierReleaseKeys() {
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 36)), .confirm)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 49)), .confirm)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 53)), .cancel)
        XCTAssertNil(SwitcherKeyboardMapper.action(for: flagsChangedEvent(keyCode: 58, modifiers: [.option])))
        XCTAssertNil(SwitcherKeyboardMapper.action(for: flagsChangedEvent(keyCode: 56, modifiers: [])))
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: flagsChangedEvent(keyCode: 58, modifiers: [])), .modifierReleased)
    }

    func testCommandModifierReleaseKeysForAllAppsMode() {
        XCTAssertNil(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 55, modifiers: [.command]),
                triggerModifier: .command
            )
        )
        XCTAssertNil(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 58, modifiers: []),
                triggerModifier: .command
            )
        )
        XCTAssertEqual(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 55, modifiers: []),
                triggerModifier: .command
            ),
            .modifierReleased
        )
    }

    func testShiftPressWhileTriggerModifierIsHeldMovesPrevious() {
        XCTAssertEqual(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 56, modifiers: [.command, .shift]),
                triggerModifier: .command
            ),
            .previous
        )
        XCTAssertEqual(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 60, modifiers: [.command, .shift]),
                triggerModifier: .command
            ),
            .previous
        )
        XCTAssertEqual(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 56, modifiers: [.option, .shift]),
                triggerModifier: .option
            ),
            .previous
        )
    }

    func testShiftPressWithoutTriggerModifierIsIgnored() {
        XCTAssertNil(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 56, modifiers: [.shift]),
                triggerModifier: .command
            )
        )
        XCTAssertNil(
            SwitcherKeyboardMapper.action(
                for: flagsChangedEvent(keyCode: 56, modifiers: [.command]),
                triggerModifier: .command
            )
        )
    }

    func testModifierReleaseFallbackUsesCurrentModifierState() {
        XCTAssertNil(SwitcherTriggerModifier.command.modifierReleaseFallbackAction(currentFlags: [.command]))
        XCTAssertNil(SwitcherTriggerModifier.option.modifierReleaseFallbackAction(currentFlags: [.option]))
        XCTAssertEqual(SwitcherTriggerModifier.command.modifierReleaseFallbackAction(currentFlags: []), .modifierReleased)
        XCTAssertEqual(SwitcherTriggerModifier.option.modifierReleaseFallbackAction(currentFlags: []), .modifierReleased)
    }

    func testNavigationHoldActionsIncludeTriggerModifierShiftWithoutTab() {
        XCTAssertEqual(
            SwitcherTriggerModifier.command.navigationHoldAction(
                currentFlags: [.command],
                isTabKeyPressed: true
            ),
            .next
        )
        XCTAssertEqual(
            SwitcherTriggerModifier.command.navigationHoldAction(
                currentFlags: [.command, .shift],
                isTabKeyPressed: true
            ),
            .previous
        )
        XCTAssertEqual(
            SwitcherTriggerModifier.command.navigationHoldAction(
                currentFlags: [.command, .shift],
                isTabKeyPressed: false
            ),
            .previous
        )
        XCTAssertNil(
            SwitcherTriggerModifier.command.navigationHoldAction(
                currentFlags: [.command],
                isTabKeyPressed: false
            )
        )
        XCTAssertEqual(
            SwitcherTriggerModifier.option.navigationHoldAction(
                currentFlags: [.option, .shift],
                isTabKeyPressed: false
            ),
            .previous
        )
    }

    func testKeyHoldRepeaterStopsAfterHeldStateClears() async {
        let repeatedTwice = expectation(description: "held key repeats twice")
        repeatedTwice.expectedFulfillmentCount = 2

        let repeater = await MainActor.run {
            var isHeld = true
            var repeatCount = 0
            return SwitcherKeyHoldRepeater(
                initialDelay: 0.01,
                repeatInterval: 0.01,
                isHeld: { isHeld },
                onRepeat: {
                    repeatCount += 1
                    repeatedTwice.fulfill()
                    if repeatCount == 2 {
                        isHeld = false
                    }
                }
            )
        }

        await MainActor.run { repeater.restart() }
        await fulfillment(of: [repeatedTwice], timeout: 1)
        await MainActor.run { repeater.stop() }
    }

    private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func flagsChangedEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
