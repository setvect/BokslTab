import AppKit
import BokslTabCore
@testable import BokslTabUI
import XCTest

final class SwitcherPanelLayoutTests: XCTestCase {
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
        for width: CGFloat in [320, 360, 800] {
            let screen = CGSize(width: width, height: 800)
            let metrics = SwitcherPanelLayout.metrics(itemCount: 7, availableSize: screen)
            XCTAssertLessThanOrEqual(metrics.panelWidth, width - SwitcherPanelLayout.screenEdgeMargin * 2)
        }
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

    func testPanelFrameStaysInsideVisibleFrameForDenseSmallScreenList() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 640, height: 420)
        let frame = SwitcherPanelLayout.panelFrame(
            itemCount: 29,
            warning: "권한 안내",
            visibleFrame: visibleFrame
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
            visibleFrame: visibleFrame
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
            visibleFrame: visibleFrame
        )
        let maxWidth = max(1, visibleFrame.width - SwitcherPanelLayout.screenEdgeMargin * 2)
        let maxHeight = max(1, visibleFrame.height - SwitcherPanelLayout.screenEdgeMargin * 2)

        XCTAssertLessThanOrEqual(metrics.panelWidth, maxWidth)
        XCTAssertLessThanOrEqual(metrics.panelHeight, visibleFrame.height)
        XCTAssertLessThanOrEqual(frame.width, maxWidth)
        XCTAssertLessThanOrEqual(frame.height, maxHeight)
    }

    func testPanelUpdateResizesForNewRowsAndReusesHostingController() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            guard NSScreen.screens.first != nil else { throw XCTSkip("No display available") }
            let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let controller = SwitcherPanelController(iconProvider: { _ in nil }, onKeyboardAction: { _ in }, onOpenSettings: {})
            let app = AppIdentity(processIdentifier: 123)
            func state(_ count: Int, selected: Int = 0) -> SwitcherState {
                SwitcherState(mode: .allAppsAndWindows, items: (0..<count).map {
                    SwitcherItem(app: app, kind: .window(WindowIdentity(windowID: UInt32($0), ownerProcessIdentifier: 123)))
                }, selectedIndex: selected)
            }
            controller.update(state: state(1), warning: nil)
            let panel = try XCTUnwrap(NSApp.windows.first { !oldWindows.contains(ObjectIdentifier($0)) })
            let hosting = try XCTUnwrap(panel.contentViewController)
            let initialFrame = panel.frame
            controller.update(state: state(8), warning: nil)
            XCTAssertGreaterThan(panel.frame.height, initialFrame.height)
            XCTAssertTrue(panel.contentViewController === hosting)
            let expanded = panel.frame
            controller.update(state: state(8, selected: 3), warning: nil)
            XCTAssertEqual(panel.frame, expanded)
            controller.update(state: state(1), warning: nil)
            XCTAssertEqual(panel.frame, initialFrame)
            controller.hide()
            panel.close()
        }
    }

    func testWarningAndEmptyStateFitInsideComputedPanel() {
        let screen = CGRect(x: 0, y: 0, width: 640, height: 420)
        for count in [0, 1, 8, 29, 50] {
            let metrics = SwitcherPanelLayout.metrics(itemCount: count, availableSize: screen.size, warning: "Warning")
            let panel = SwitcherPanelLayout.panelFrame(itemCount: count, warning: "Warning", visibleFrame: screen)
            XCTAssertLessThanOrEqual(metrics.panelHeight + 28, panel.height)
        }
    }
}
