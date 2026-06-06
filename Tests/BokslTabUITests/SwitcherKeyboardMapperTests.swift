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

    func testConfirmAndCancelKeys() {
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 36)), .confirm)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 49)), .confirm)
        XCTAssertEqual(SwitcherKeyboardMapper.action(for: keyEvent(keyCode: 53)), .cancel)
    }


    func testPanelListHeightReservesVisibleRows() {
        XCTAssertEqual(SwitcherPanelLayout.listHeight(itemCount: 0), SwitcherPanelLayout.rowHeight)
        XCTAssertEqual(
            SwitcherPanelLayout.listHeight(itemCount: 3),
            SwitcherPanelLayout.rowHeight * 3 + SwitcherPanelLayout.rowSpacing * 2
        )
        XCTAssertEqual(
            SwitcherPanelLayout.listHeight(itemCount: 99),
            SwitcherPanelLayout.rowHeight * CGFloat(SwitcherPanelLayout.maxVisibleRows)
                + SwitcherPanelLayout.rowSpacing * CGFloat(SwitcherPanelLayout.maxVisibleRows - 1)
        )
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
}
