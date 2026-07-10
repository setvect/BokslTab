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

    func testAppDefinedKeyRepeatTimingUsesTwoHundredThenOneHundredMilliseconds() {
        XCTAssertEqual(SwitcherKeyRepeatTiming.initialDelay, 0.2)
        XCTAssertEqual(SwitcherKeyRepeatTiming.repeatInterval, 0.1)
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

    func testPanelMetricsUsesScrollOnlyAtThresholdWhenReadable() {
        let largeScreen = CGSize(width: 1600, height: 2000)

        XCTAssertFalse(SwitcherPanelLayout.metrics(itemCount: 1, availableSize: largeScreen).usesScroll)
        XCTAssertFalse(SwitcherPanelLayout.metrics(itemCount: 7, availableSize: largeScreen).usesScroll)
        XCTAssertFalse(SwitcherPanelLayout.metrics(itemCount: 29, availableSize: largeScreen).usesScroll)
        XCTAssertTrue(SwitcherPanelLayout.metrics(itemCount: 30, availableSize: largeScreen).usesScroll)
        XCTAssertTrue(SwitcherPanelLayout.metrics(itemCount: 31, availableSize: largeScreen).usesScroll)
    }

    func testPanelMetricsGuardrailScrollsWhenRowsWouldBeUnreadable() {
        let smallScreen = CGSize(width: 800, height: 420)
        let metrics = SwitcherPanelLayout.metrics(itemCount: 29, availableSize: smallScreen)

        XCTAssertTrue(metrics.usesScroll)
        XCTAssertGreaterThanOrEqual(metrics.rowHeight, SwitcherPanelLayout.minimumRowHeight)
        XCTAssertLessThanOrEqual(metrics.panelHeight, smallScreen.height)
    }

    func testPanelMetricsShrinkAsItemCountGrows() {
        let screen = CGSize(width: 1600, height: 1000)
        let sparse = SwitcherPanelLayout.metrics(itemCount: 7, availableSize: screen)
        let dense = SwitcherPanelLayout.metrics(itemCount: 29, availableSize: screen)

        XCTAssertLessThanOrEqual(dense.rowHeight, sparse.rowHeight)
        XCTAssertLessThanOrEqual(dense.iconSize, sparse.iconSize)
        XCTAssertLessThanOrEqual(dense.fontSize, sparse.fontSize)
    }

    func testPanelMetricsClampWidthForSmallScreens() {
        let smallScreen = CGSize(width: 360, height: 800)
        let metrics = SwitcherPanelLayout.metrics(itemCount: 7, availableSize: smallScreen)

        XCTAssertLessThanOrEqual(metrics.panelWidth, smallScreen.width - SwitcherPanelLayout.screenEdgeMargin * 2)
    }

    func testPanelMetricsScaleWithScreenHeight() {
        let fullHD = CGSize(width: 1920, height: 1080)
        let qhd = CGSize(width: 2560, height: 1440)
        let fullHDMetrics = SwitcherPanelLayout.metrics(itemCount: 7, availableSize: fullHD)
        let qhdMetrics = SwitcherPanelLayout.metrics(itemCount: 7, availableSize: qhd)

        XCTAssertEqual(SwitcherPanelLayout.resolutionScale(for: fullHD), 0.75, accuracy: 0.01)
        XCTAssertEqual(SwitcherPanelLayout.resolutionScale(for: qhd), 1.0, accuracy: 0.01)
        XCTAssertLessThan(fullHDMetrics.panelWidth, qhdMetrics.panelWidth)
        XCTAssertLessThan(fullHDMetrics.rowHeight, qhdMetrics.rowHeight)
        XCTAssertLessThan(fullHDMetrics.iconSize, qhdMetrics.iconSize)
        XCTAssertLessThan(fullHDMetrics.fontSize, qhdMetrics.fontSize)
    }

    func testPanelMetricsUseMinimumResolutionScaleForShortScreens() {
        let shortScreen = CGSize(width: 1280, height: 800)

        XCTAssertEqual(
            SwitcherPanelLayout.resolutionScale(for: shortScreen),
            SwitcherPanelLayout.minimumResolutionScale,
            accuracy: 0.01
        )
    }

    func testPanelMetricsClampWidthToAvailableScreen() {
        let narrowScreen = CGSize(width: 320, height: 800)
        let metrics = SwitcherPanelLayout.metrics(itemCount: 7, availableSize: narrowScreen)

        XCTAssertLessThanOrEqual(metrics.panelWidth, narrowScreen.width - SwitcherPanelLayout.screenEdgeMargin * 2)
    }

    func testPanelFrameStaysInsideVisibleFrameForDenseSmallScreenList() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 640, height: 420)
        let frame = SwitcherPanelLayout.panelFrame(
            itemCount: 29,
            warning: "권한 안내",
            visibleFrame: visibleFrame,
            fittingSize: CGSize(width: 900, height: 900)
        )

        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + SwitcherPanelLayout.screenEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - SwitcherPanelLayout.screenEdgeMargin)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + SwitcherPanelLayout.screenEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - SwitcherPanelLayout.screenEdgeMargin)
    }

    func testPanelFrameClampsUpwardOffsetNearScreenEdges() {
        let visibleFrame = CGRect(x: -1440, y: -900, width: 500, height: 360)
        let frame = SwitcherPanelLayout.panelFrame(
            itemCount: 31,
            warning: nil,
            visibleFrame: visibleFrame,
            fittingSize: CGSize(width: 560, height: 800)
        )

        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + SwitcherPanelLayout.screenEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - SwitcherPanelLayout.screenEdgeMargin)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + SwitcherPanelLayout.screenEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY - SwitcherPanelLayout.screenEdgeMargin)
    }

    func testPanelMetricsAndFrameDoNotExceedTinyScreens() {
        let visibleFrame = CGRect(x: 10, y: 20, width: 90, height: 50)
        let metrics = SwitcherPanelLayout.metrics(itemCount: 29, availableSize: visibleFrame.size)
        let frame = SwitcherPanelLayout.panelFrame(
            itemCount: 29,
            warning: "권한 안내",
            visibleFrame: visibleFrame,
            fittingSize: CGSize(width: 500, height: 500)
        )
        let maxWidth = max(1, visibleFrame.width - SwitcherPanelLayout.screenEdgeMargin * 2)
        let maxHeight = max(1, visibleFrame.height - SwitcherPanelLayout.screenEdgeMargin * 2)

        XCTAssertLessThanOrEqual(metrics.panelWidth, maxWidth)
        XCTAssertLessThanOrEqual(metrics.panelHeight, visibleFrame.height)
        XCTAssertLessThanOrEqual(frame.width, maxWidth)
        XCTAssertLessThanOrEqual(frame.height, maxHeight)
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
