import ApplicationServices
import Foundation

/// One bounded operation. Passed explicitly through every AX read and action.
final class AccessibilityQueryBudget {
    static let messagingTimeout: TimeInterval = 0.08
    static let processTimeout: TimeInterval = 0.25

    private let now: () -> TimeInterval
    private let deadline: TimeInterval
    private let requestTimeout: TimeInterval
    private let isCancelled: () -> Bool
    private let api: AccessibilityAPI
    private(set) var failed = false

    init(
        duration: TimeInterval = processTimeout,
        requestTimeout: TimeInterval = messagingTimeout,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isCancelled: @escaping () -> Bool = { false },
        api: AccessibilityAPI = .live
    ) {
        self.now = now
        self.deadline = now() + duration
        self.requestTimeout = requestTimeout
        self.isCancelled = isCancelled
        self.api = api
    }

    var reader: AXElementReader { AXElementReader(query: self) }

    var remainingTimeout: TimeInterval? {
        guard !failed, !isCancelled() else { return nil }
        let remaining = deadline - now()
        guard remaining > 0 else {
            failed = true
            return nil
        }
        return min(requestTimeout, remaining)
    }

    var isExhausted: Bool { remainingTimeout == nil }

    func record(_ error: AXError) {
        if error == .cannotComplete { failed = true }
    }

    func prepare(_ element: AXUIElement) -> Bool {
        guard let timeout = remainingTimeout else { return false }
        let error = api.setTimeout(element, Float(timeout))
        record(error)
        return error == .success
    }

    func withTimeout(on element: AXUIElement, _ operation: () -> AXError) -> AXError {
        guard prepare(element) else { return .cannotComplete }
        defer { _ = api.setTimeout(element, 0) }
        let error = operation()
        record(error)
        return error
    }

    func copyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
        withTimeout(on: element) { api.copyAttribute(element, attribute, value) }
    }

    func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        withTimeout(on: element) { api.setAttribute(element, attribute, value) }
    }

    func performAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        withTimeout(on: element) { api.performAction(element, action) }
    }
}

/// The system boundary is replaceable without bypassing timeout/cooldown policy in tests.
struct AccessibilityAPI {
    var setTimeout: (AXUIElement, Float) -> AXError
    var copyAttribute: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError
    var setAttribute: (AXUIElement, CFString, CFTypeRef) -> AXError
    var performAction: (AXUIElement, CFString) -> AXError

    static let live = AccessibilityAPI(
        setTimeout: AXUIElementSetMessagingTimeout,
        copyAttribute: AXUIElementCopyAttributeValue,
        setAttribute: AXUIElementSetAttributeValue,
        performAction: AXUIElementPerformAction
    )
}
