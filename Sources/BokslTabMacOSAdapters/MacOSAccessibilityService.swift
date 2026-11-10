import Foundation

/// Shared by the catalog, event observer and activator; owns all retry decisions.
public final class MacOSAccessibilityService: @unchecked Sendable {
    let workerQueue = DispatchQueue(label: "dev.boksl.BokslTab.accessibility", qos: .userInitiated)
    let windowElements = AccessibilityWindowElementCache()
    /// Every window seen so far, by window number. The catalog, the event observer and the activator
    /// share it, so a window has one identity and one remembered title.
    let knownWindows = SeenWindowRegistry()
    // The event observer is initialized under the same lock; its AX work uses workerQueue.
    private var storedEventObserver: AccessibilityWindowEventObserver?
    var eventObserver: AccessibilityWindowEventObserver {
        lock.lock()
        defer { lock.unlock() }
        if let storedEventObserver { return storedEventObserver }
        let observer = AccessibilityWindowEventObserver(accessibility: self)
        storedEventObserver = observer
        return observer
    }
    private let lock = NSLock()
    private var storedWindowFocusHandler: ((_ windowID: UInt32, _ processIdentifier: Int32) -> Void)?
    /// Called on the AX worker queue when an observed app reports that one of its windows took focus,
    /// such as a project tab clicked inside the app. No app activation announces that switch.
    var windowFocusHandler: ((_ windowID: UInt32, _ processIdentifier: Int32) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedWindowFocusHandler
        }
        set {
            lock.lock()
            storedWindowFocusHandler = newValue
            lock.unlock()
        }
    }
    private var retryAfterByPID: [Int32: TimeInterval] = [:]
    private var consecutiveFailuresByPID: [Int32: Int] = [:]
    private let retryDelay: TimeInterval
    private let now: () -> TimeInterval
    private let api: AccessibilityAPI

    public convenience init() { self.init(api: .live) }

    init(
        api: AccessibilityAPI,
        retryDelay: TimeInterval = 15,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.api = api
        self.retryDelay = retryDelay
        self.now = now
    }

    /// The wait after the first failure. An app that is merely busy, like IntelliJ while it switches
    /// projects, answers again within a second or two; one missed request must not cost fifteen.
    static let firstRetryDelay: TimeInterval = 1

    func isCoolingDown(_ pid: Int32) -> Bool {
        secondsUntilRetry(pid) > 0
    }

    func secondsUntilRetry(_ pid: Int32) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(0, (retryAfterByPID[pid] ?? 0) - now())
    }

    func retainOnly(_ pids: Set<Int32>) {
        lock.lock()
        retryAfterByPID = retryAfterByPID.filter { pids.contains($0.key) }
        consecutiveFailuresByPID = consecutiveFailuresByPID.filter { pids.contains($0.key) }
        lock.unlock()
        windowElements.retainOnly(pids)
        knownWindows.retainOnly(pids)
    }

    // Called only on workerQueue. AX handles and their messaging timeouts stay serialized.
    func perform<Value>(
        for pid: Int32,
        duration: TimeInterval = AccessibilityQueryBudget.processTimeout,
        requestTimeout: TimeInterval = AccessibilityQueryBudget.messagingTimeout,
        isCancelled: @escaping () -> Bool = { false },
        _ body: (AccessibilityQueryBudget) -> Value?
    ) -> Value? {
        guard !isCancelled(), !isCoolingDown(pid) else { return nil }
        let query = AccessibilityQueryBudget(
            duration: duration, requestTimeout: requestTimeout,
            now: now, isCancelled: isCancelled, api: api
        )
        let value = body(query)
        guard !isCancelled() else { return nil }
        _ = query.remainingTimeout
        if query.failed {
            // The wait doubles while the app keeps failing, up to `retryDelay` for one that hangs.
            lock.lock()
            let failures = (consecutiveFailuresByPID[pid] ?? 0) + 1
            consecutiveFailuresByPID[pid] = failures
            let delay = min(retryDelay, Self.firstRetryDelay * pow(2, Double(min(failures, 16) - 1)))
            retryAfterByPID[pid] = now() + delay
            lock.unlock()
            BokslTabDiagnosticLog.write(
                "accessibility.deferred pid=\(pid) retryAfterSeconds=\(Int(delay)) failures=\(failures)"
            )
            return nil
        }
        lock.lock()
        consecutiveFailuresByPID.removeValue(forKey: pid)
        lock.unlock()
        return value
    }

    func run<Value>(
        for pid: Int32,
        duration: TimeInterval = AccessibilityQueryBudget.processTimeout,
        requestTimeout: TimeInterval = AccessibilityQueryBudget.messagingTimeout,
        _ body: @escaping (AccessibilityQueryBudget) -> Value?
    ) async -> Value? {
        let cancellation = QueryCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workerQueue.async {
                    let value = self.perform(
                        for: pid, duration: duration, requestTimeout: requestTimeout,
                        isCancelled: { cancellation.isCancelled }, body
                    )
                    continuation.resume(returning: value)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
