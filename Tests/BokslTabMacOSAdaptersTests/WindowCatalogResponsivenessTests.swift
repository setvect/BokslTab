import ApplicationServices
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
        let accessibility = MacOSAccessibilityService()
        let started = expectation(description: "unresponsive app query started")
        let healthyLoaded = expectation(description: "healthy app details published")
        let release = DispatchSemaphore(value: 0)
        var slowLoads = 0
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
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
        provider.requestRefresh(including: [])
        let first = provider.windowsForAllApps()
        XCTAssertEqual(first.map(\.windowID), [10, 20])
        wait(for: [started], timeout: 1)
        for _ in 0..<5 {
            XCTAssertEqual(provider.windowsForAllApps().map(\.windowID), [10, 20])
        }
        release.signal()
        wait(for: [healthyLoaded], timeout: 1)
        accessibility.workerQueue.sync {}
        let detailed = provider.windowsForAllApps()
        XCTAssertEqual(detailed.first { $0.windowID == 20 }?.title, "Healthy Details")
        XCTAssertNotNil(detailed.first { $0.windowID == 10 })
        accessibility.workerQueue.sync {}
        XCTAssertEqual(slowLoads, 1)
        provider.onDidRefresh = nil
    }

    func testClosedWindowIsNotReintroducedFromAccessibilityCache() {
        let accessibility = MacOSAccessibilityService()
        var liveInfo = [info(pid: 999_103, windowID: 10)]
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { liveInfo },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                [AccessibilityWindowSnapshot(title: "Closed", frame: self.frame)]
            }
        )
        provider.requestRefresh(including: [])
        XCTAssertEqual(provider.windowsForAllApps().count, 1)
        accessibility.workerQueue.sync {}
        liveInfo = []
        XCTAssertTrue(provider.windowsForAllApps().isEmpty)
    }

    func testRevokedPermissionDropsCachedAccessibilityTitles() {
        let accessibility = MacOSAccessibilityService()
        var trusted = true
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { [self.info(pid: 999_104, windowID: 10)] },
            isAccessibilityTrusted: { trusted },
            accessibilitySnapshotLoader: { _, _ in
                [AccessibilityWindowSnapshot(title: "Private Title", frame: self.frame)]
            }
        )
        provider.requestRefresh(including: [])
        _ = provider.windowsForAllApps()
        accessibility.workerQueue.sync {}
        XCTAssertEqual(provider.windowsForAllApps().first?.title, "Private Title")
        trusted = false
        XCTAssertNil(provider.windowsForAllApps().first?.title)
    }
    func testReadAndRefreshCallbackDoNotStartAnotherRoundOfAXQueries() {
        let accessibility = MacOSAccessibilityService()
        let loaded = expectation(description: "coalesced details")
        let app = AppIdentity(processIdentifier: 999_106)
        var loads = 0
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { [self.info(pid: app.processIdentifier, windowID: 10)] },
            isAccessibilityTrusted: { true },
            accessibilitySnapshotLoader: { _, _ in
                loads += 1
                return [AccessibilityWindowSnapshot(title: "Details", frame: self.frame)]
            }
        )
        _ = provider.windowsForAllApps(including: [app])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(loads, 0)
        provider.onDidRefresh = {
            for _ in 0..<5 { _ = provider.windowsForAllApps(including: [app]) }
            loaded.fulfill()
        }
        provider.requestRefresh(including: [app])
        wait(for: [loaded], timeout: 1)
        accessibility.workerQueue.sync {}
        XCTAssertEqual(loads, 1)
        provider.onDidRefresh = nil
    }
    func testCatalogUsesSharedBudgetAtTheActualAXReadBoundary() {
        var api = testAccessibilityAPI()
        var calls: [Int32: Int] = [:]
        api.copyAttribute = { element, _, _ in
            XCTAssertFalse(Thread.isMainThread)
            var pid: pid_t = 0
            XCTAssertEqual(AXUIElementGetPid(element, &pid), .success)
            calls[pid, default: 0] += 1
            return pid == 999_107 ? .cannotComplete : .attributeUnsupported
        }
        let accessibility = MacOSAccessibilityService(api: api)
        let provider = MacOSWindowCatalogProvider(
            accessibility: accessibility,
            windowInfoList: { [self.info(pid: 999_107, windowID: 10), self.info(pid: 999_108, windowID: 20)] },
            isAccessibilityTrusted: { true }
        )
        provider.requestRefresh(including: [])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(calls[999_107], 1)
        XCTAssertEqual(calls[999_108], 3)
        XCTAssertTrue(accessibility.isCoolingDown(999_107))
        XCTAssertFalse(accessibility.isCoolingDown(999_108))
        XCTAssertEqual(provider.windowsForAllApps().map(\.windowID), [10, 20])
        provider.requestRefresh(including: [])
        accessibility.workerQueue.sync {}
        XCTAssertEqual(calls[999_107], 1)
    }
}
