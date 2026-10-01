import BokslTabCore
import CoreGraphics
import XCTest
@testable import BokslTabMacOSAdapters

final class WindowCatalogResponsivenessTests: XCTestCase {
    private let frame = CGRect(x: 50, y: 50, width: 800, height: 600)

    private func info(pid: Int32, windowID: UInt32) -> [String: Any] {
        [
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowOwnerName as String: "Test App",
            kCGWindowBounds as String: frame.dictionaryRepresentation
        ]
    }

    func testBasicCatalogReturnsWhileOneAppIsBlockedAndHealthyDetailsStillArrive() {
        let eventCache = AccessibilityWindowEventCache()
        let started = expectation(description: "unresponsive app query started")
        let healthyLoaded = expectation(description: "healthy app details published")
        let release = DispatchSemaphore(value: 0)
        var slowLoads = 0
        let provider = MacOSWindowCatalogProvider(
            accessibilityEventCache: eventCache,
            windowInfoList: { [self.info(pid: 999_101, windowID: 10), self.info(pid: 999_102, windowID: 20)] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { pid, _ in
                XCTAssertFalse(Thread.isMainThread)
                if pid == 999_101 {
                    slowLoads += 1
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 2)
                    return nil
                }
                return [AccessibilityWindowSnapshot(title: "Healthy Details", frame: self.frame)]
            }
        )
        provider.onDidRefresh = { healthyLoaded.fulfill() }
        let first = provider.windowsForAllApps()
        XCTAssertEqual(first.map(\.windowID), [10, 20])
        wait(for: [started], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {
            XCTAssertEqual(provider.windowsForAllApps().map(\.windowID), [10, 20])
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        release.signal()
        wait(for: [healthyLoaded], timeout: 1)
        eventCache.workerQueue.sync {}
        let detailed = provider.windowsForAllApps()
        XCTAssertEqual(detailed.first { $0.windowID == 20 }?.title, "Healthy Details")
        XCTAssertNotNil(detailed.first { $0.windowID == 10 })
        eventCache.workerQueue.sync {}
        XCTAssertEqual(slowLoads, 1)
        provider.onDidRefresh = nil
    }

    func testClosedWindowIsNotReintroducedFromAccessibilityCache() {
        let eventCache = AccessibilityWindowEventCache()
        var liveInfo = [info(pid: 999_103, windowID: 10)]
        let provider = MacOSWindowCatalogProvider(
            accessibilityEventCache: eventCache,
            windowInfoList: { liveInfo },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                [AccessibilityWindowSnapshot(title: "Closed", frame: self.frame)]
            }
        )
        XCTAssertEqual(provider.windowsForAllApps().count, 1)
        eventCache.workerQueue.sync {}
        liveInfo = []
        XCTAssertTrue(provider.windowsForAllApps().isEmpty)
    }

    func testRevokedPermissionDropsCachedAccessibilityTitles() {
        let eventCache = AccessibilityWindowEventCache()
        var trusted = true
        let provider = MacOSWindowCatalogProvider(
            accessibilityEventCache: eventCache,
            windowInfoList: { [self.info(pid: 999_104, windowID: 10)] },
            isAccessibilityTrusted: { trusted },
            accessibilitySnapshotLoader: { _, _ in
                [AccessibilityWindowSnapshot(title: "Private Title", frame: self.frame)]
            }
        )
        _ = provider.windowsForAllApps()
        eventCache.workerQueue.sync {}
        XCTAssertEqual(provider.windowsForAllApps().first?.title, "Private Title")
        trusted = false
        XCTAssertNil(provider.windowsForAllApps().first?.title)
    }
}
