import ApplicationServices
import XCTest
@testable import BokslTabMacOSAdapters

final class BackgroundRefreshCacheTests: XCTestCase {
    func testBlockedLoaderDoesNotBlockReadersAndRepeatedRequestsAreCoalesced() {
        let queue = DispatchQueue(label: "cache-test")
        let cache = BackgroundRefreshCache<Int, String>(queue: queue)
        let started = expectation(description: "background loader started")
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "refresh delivered on main")
        cache.onRefresh = {
            XCTAssertTrue(Thread.isMainThread)
            finished.fulfill()
        }
        var loads = 0
        cache.refresh(1) {
            XCTAssertFalse(Thread.isMainThread)
            loads += 1
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            return "details"
        }
        wait(for: [started], timeout: 1)
        for _ in 0..<100 {
            XCTAssertNil(cache.value(for: 1))
            cache.refresh(1) { XCTFail("duplicate load"); return "duplicate" }
        }
        release.signal()
        wait(for: [finished], timeout: 1)
        queue.sync {}
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(cache.value(for: 1), "details")
    }

    func testCompletedAppsShareOneMainQueueNotification() {
        let queue = DispatchQueue(label: "batch-test")
        let cache = BackgroundRefreshCache<Int, String>(queue: queue)
        let notified = expectation(description: "one notification for the batch")
        cache.onRefresh = {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(cache.value(for: 1), "one")
            XCTAssertEqual(cache.value(for: 2), "two")
            notified.fulfill()
        }
        cache.refresh(1) { "one" }
        cache.refresh(2) { "two" }
        queue.sync {}
        wait(for: [notified], timeout: 1)
        cache.onRefresh = nil
    }

    func testKeepsRecentDetailsOnFailureButExpiresStaleTabs() {
        let queue = DispatchQueue(label: "expiry-test")
        let clock = TestClock()
        let cache = BackgroundRefreshCache<Int, String>(queue: queue, now: { clock.time })
        cache.refresh(1) { "previous details" }
        queue.sync {}
        clock.advance(1)
        cache.refresh(1) { nil }
        queue.sync {}
        XCTAssertEqual(cache.value(for: 1), "previous details")
        clock.advance(5)
        XCTAssertNil(cache.value(for: 1))
    }

    func testRemovedAppCannotBeResurrectedByInFlightResult() {
        let queue = DispatchQueue(label: "prune-test")
        let cache = BackgroundRefreshCache<Int, String>(queue: queue)
        let started = expectation(description: "started")
        let release = DispatchSemaphore(value: 0)
        cache.refresh(1) {
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return "closed app"
        }
        wait(for: [started], timeout: 1)
        cache.retainOnly([])
        release.signal()
        queue.sync {}
        XCTAssertNil(cache.value(for: 1))
    }

}

final class TestClock {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var time: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func advance(_ duration: TimeInterval) {
        lock.lock()
        value += duration
        lock.unlock()
    }
}
