import BokslTabCore
import CoreGraphics
import XCTest
@testable import BokslTabMacOSAdapters

/// Two maximized windows of one app share their frame, so only the window number tells them apart.
final class WindowIdentityMatchingTests: XCTestCase {
    private let maximized = CGRect(x: 0, y: 30, width: 2560, height: 1410)

    private func info(pid: Int32, windowID: UInt32) -> [String: Any] {
        [
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowOwnerName as String: "Code",
            kCGWindowBounds as String: maximized.dictionaryRepresentation
        ]
    }

    private func detailedWindows(
        cgWindowIDs: [UInt32],
        pid: Int32,
        accessibilityWindows: [AccessibilityWindowSnapshot]
    ) -> [UInt32: String?] {
        let accessibility = MacOSAccessibilityService()
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { cgWindowIDs.map { self.info(pid: pid, windowID: $0) } },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in accessibilityWindows }
        )
        provider.requestRefresh(including: [])
        accessibility.workerQueue.sync {}
        return Dictionary(uniqueKeysWithValues: provider.windowsForAllApps().map { ($0.windowID, $0.title) })
    }

    /// Reported at 21:14: titles were handed out by sorted window number and sorted title,
    /// so the row for #95 carried #97's title and switching to it raised #97.
    func testCatalogLabelsSameFrameWindowsByWindowNumberNotByTitleOrder() {
        let titles = detailedWindows(
            cgWindowIDs: [97, 95],
            pid: 999_201,
            accessibilityWindows: [
                AccessibilityWindowSnapshot(windowID: 97, title: "Alpha — BokslTab", frame: maximized),
                AccessibilityWindowSnapshot(windowID: 95, title: "Zeta — BokslDir", frame: maximized)
            ]
        )

        XCTAssertEqual(titles[95], "Zeta — BokslDir")
        XCTAssertEqual(titles[97], "Alpha — BokslTab")
    }

    func testCatalogDoesNotLendTitleOfIdentifiedWindowThatIsNotOnScreen() {
        let titles = detailedWindows(
            cgWindowIDs: [10],
            pid: 999_202,
            accessibilityWindows: [
                AccessibilityWindowSnapshot(windowID: 11, title: "Minimized sibling", frame: maximized)
            ]
        )

        XCTAssertEqual(titles.keys.sorted(), [10])
        XCTAssertNil(titles[10] ?? nil)
    }

    func testCatalogStillUsesGeometryWhenWindowNumbersAreUnavailable() {
        let titles = detailedWindows(
            cgWindowIDs: [10],
            pid: 999_203,
            accessibilityWindows: [
                AccessibilityWindowSnapshot(title: "Only window", frame: maximized)
            ]
        )

        XCTAssertEqual(titles[10], "Only window")
    }
}
