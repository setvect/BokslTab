import ApplicationServices
import Foundation

/// A budget belongs to one synchronous background query, including child elements.
/// AX timeouts are per element; setting one on the application does not cover its windows.
final class AccessibilityQueryBudget {
    static let messagingTimeout: TimeInterval = 0.08
    static let processTimeout: TimeInterval = 0.25
    static let retryDelay: TimeInterval = 15
    private static let contextKey = "dev.boksl.BokslTab.accessibilityQueryBudget"
    private static let retryLock = NSLock()
    private static var retryAfterByPID: [Int32: TimeInterval] = [:]

    private let now: () -> TimeInterval
    private let deadline: TimeInterval
    private(set) var failed = false

    init(duration: TimeInterval = processTimeout, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.deadline = now() + duration
    }

    var remainingTimeout: TimeInterval? {
        guard !failed else { return nil }
        let remaining = deadline - now()
        guard remaining > 0 else {
            failed = true
            return nil
        }
        return min(Self.messagingTimeout, remaining)
    }

    func record(_ error: AXError) {
        if error == .cannotComplete {
            failed = true
        }
    }

    static func isCoolingDown(_ processIdentifier: Int32) -> Bool {
        retryLock.lock()
        defer { retryLock.unlock() }
        return (retryAfterByPID[processIdentifier] ?? 0) > ProcessInfo.processInfo.systemUptime
    }

    static func perform<Value>(for processIdentifier: Int32, _ body: () -> Value) -> Value? {
        guard !isCoolingDown(processIdentifier) else { return nil }
        let budget = AccessibilityQueryBudget()
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[contextKey]
        dictionary[contextKey] = budget
        defer { dictionary[contextKey] = previous }
        let value = body()
        _ = budget.remainingTimeout
        if budget.failed {
            retryLock.lock()
            retryAfterByPID[processIdentifier] = ProcessInfo.processInfo.systemUptime + retryDelay
            retryLock.unlock()
            BokslTabDiagnosticLog.write("window-catalog.ax.deferred pid=\(processIdentifier) retryAfterSeconds=\(Int(retryDelay)) reason=timeout-or-unresponsive")
            return nil
        }
        retryLock.lock()
        retryAfterByPID.removeValue(forKey: processIdentifier)
        retryLock.unlock()
        return value
    }

    static func prune(to processIdentifiers: Set<Int32>) {
        retryLock.lock()
        retryAfterByPID = retryAfterByPID.filter { processIdentifiers.contains($0.key) }
        retryLock.unlock()
    }

    static var currentQueryFailed: Bool {
        guard let budget = Thread.current.threadDictionary[contextKey] as? AccessibilityQueryBudget else { return false }
        _ = budget.remainingTimeout
        return budget.failed
    }

    static func prepare(_ element: AXUIElement) -> Bool {
        guard let budget = Thread.current.threadDictionary[contextKey] as? AccessibilityQueryBudget else { return true }
        guard let timeout = budget.remainingTimeout else { return false }
        let error = AXUIElementSetMessagingTimeout(element, Float(timeout))
        budget.record(error)
        return error == .success
    }

    static func recordCurrent(_ error: AXError) {
        (Thread.current.threadDictionary[contextKey] as? AccessibilityQueryBudget)?.record(error)
    }

    static func copyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
        let hasBudget = Thread.current.threadDictionary[contextKey] is AccessibilityQueryBudget
        guard prepare(element) else { return .cannotComplete }
        defer {
            // Event-cache elements can later be used for activation. Do not leave a
            // discovery timeout on them: actions may legitimately take longer.
            if hasBudget { _ = AXUIElementSetMessagingTimeout(element, 0) }
        }
        let error = AXUIElementCopyAttributeValue(element, attribute, value)
        recordCurrent(error)
        return error
    }
}
