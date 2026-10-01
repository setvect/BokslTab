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
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            XCTAssertNil(cache.value(for: 1))
            cache.refresh(1) { XCTFail("duplicate load"); return "duplicate" }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        release.signal()
        wait(for: [finished], timeout: 1)
        queue.sync {}
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(cache.value(for: 1), "details")
    }

    func testFailureDefersOnlyThatAppAndEventuallyRetries() {
        let queue = DispatchQueue(label: "retry-test")
        let clock = TestClock()
        let cache = BackgroundRefreshCache<Int, String>(queue: queue, now: { clock.time })
        var failedLoads = 0
        cache.refresh(1) { failedLoads += 1; return nil }
        cache.refresh(2) { "healthy" }
        queue.sync {}
        cache.refresh(1) { failedLoads += 1; return "recovered" }
        queue.sync {}
        XCTAssertEqual(failedLoads, 1)
        XCTAssertEqual(cache.value(for: 2), "healthy")
        clock.advance(16)
        cache.refresh(1) { failedLoads += 1; return "recovered" }
        queue.sync {}
        XCTAssertEqual(failedLoads, 2)
        XCTAssertEqual(cache.value(for: 1), "recovered")
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

    func testBudgetStopsAfterFirstUnresponsiveRequest() {
        let budget = AccessibilityQueryBudget()
        budget.record(.attributeUnsupported)
        XCTAssertNotNil(budget.remainingTimeout)
        budget.record(.cannotComplete)
        XCTAssertNil(budget.remainingTimeout)
        XCTAssertTrue(budget.failed)
    }

    func testBudgetBoundsEachRequestAndTotalProcessTime() {
        let clock = TestClock()
        let budget = AccessibilityQueryBudget(now: { clock.time })
        XCTAssertEqual(budget.remainingTimeout!, 0.08, accuracy: 0.001)
        clock.advance(0.22)
        XCTAssertEqual(budget.remainingTimeout!, 0.03, accuracy: 0.001)
        clock.advance(0.04)
        XCTAssertNil(budget.remainingTimeout)
        XCTAssertTrue(budget.failed)
    }

    func testQueryFailureCooldownPreventsFurtherAXRequests() {
        let pid: Int32 = -12345
        AccessibilityQueryBudget.prune(to: [])
        let result: String? = AccessibilityQueryBudget.perform(for: pid) {
            AccessibilityQueryBudget.recordCurrent(.cannotComplete)
            return "partial results"
        }
        XCTAssertNil(result)
        XCTAssertTrue(AccessibilityQueryBudget.isCoolingDown(pid))
        let retry: String? = AccessibilityQueryBudget.perform(for: pid) {
            XCTFail("must not query an unresponsive app again")
            return "retry"
        }
        XCTAssertNil(retry)
        AccessibilityQueryBudget.prune(to: [])
    }
}

private final class TestClock {
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
