import ApplicationServices
import XCTest
@testable import BokslTabMacOSAdapters

final class AccessibilityQueryTests: XCTestCase {
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

    func testOneCooldownOwnerSkipsFailedAppButAllowsOthersAndRetriesOnTime() {
        let clock = TestClock()
        var api = testAccessibilityAPI()
        var calls = 0
        var shouldFail = true
        api.copyAttribute = { _, _, _ in
            calls += 1
            return shouldFail ? .cannotComplete : .success
        }
        let service = MacOSAccessibilityService(api: api, now: { clock.time })
        let element = AXUIElementCreateApplication(123)
        func read(_ pid: Int32) -> Bool? {
            service.workerQueue.sync {
                service.perform(for: pid) { query in
                    var value: CFTypeRef?
                    _ = query.copyAttributeValue(element, kAXTitleAttribute as CFString, &value)
                    _ = query.copyAttributeValue(element, kAXTitleAttribute as CFString, &value)
                    return true
                }
            }
        }
        XCTAssertNil(read(1))
        XCTAssertEqual(calls, 1)
        shouldFail = false
        clock.advance(14)
        XCTAssertNil(read(1))
        XCTAssertEqual(read(2), true)
        XCTAssertEqual(calls, 3)
        // Skipping a request during cooldown must not extend the retry deadline.
        clock.advance(2)
        XCTAssertEqual(read(1), true)
        XCTAssertEqual(calls, 5)
    }

    func testActionTimeoutPreventsFurtherActionsAndUsesSameCooldown() {
        var api = testAccessibilityAPI()
        var actions = 0
        api.performAction = { _, _ in actions += 1; return .cannotComplete }
        let service = MacOSAccessibilityService(api: api)
        service.workerQueue.sync {
            let result: Bool? = service.perform(for: 1, duration: 1, requestTimeout: 0.25) { query in
                let element = AXUIElementCreateApplication(1)
                _ = query.performAction(element, kAXRaiseAction as CFString)
                _ = query.performAction(element, kAXRaiseAction as CFString)
                return true
            }
            XCTAssertNil(result)
        }
        XCTAssertEqual(actions, 1)
        XCTAssertTrue(service.isCoolingDown(1))
    }
}
