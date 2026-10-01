import Foundation

/// Shared by the catalog, event observer and activator; owns all retry decisions.
public final class MacOSAccessibilityService: @unchecked Sendable {
    let workerQueue = DispatchQueue(label: "dev.boksl.BokslTab.accessibility", qos: .userInitiated)
    // The event cache is initialized under the same lock; its AX work uses workerQueue.
    private var storedEventCache: AccessibilityWindowEventCache?
    var eventCache: AccessibilityWindowEventCache {
        lock.lock()
        defer { lock.unlock() }
        if let storedEventCache { return storedEventCache }
        let cache = AccessibilityWindowEventCache(accessibility: self)
        storedEventCache = cache
        return cache
    }
    private let lock = NSLock()
    private var retryAfterByPID: [Int32: TimeInterval] = [:]
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

    func isCoolingDown(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (retryAfterByPID[pid] ?? 0) > now()
    }

    func retainOnly(_ pids: Set<Int32>) {
        lock.lock()
        retryAfterByPID = retryAfterByPID.filter { pids.contains($0.key) }
        lock.unlock()
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
            lock.lock()
            retryAfterByPID[pid] = now() + retryDelay
            lock.unlock()
            BokslTabDiagnosticLog.write("accessibility.deferred pid=\(pid) retryAfterSeconds=\(Int(retryDelay))")
            return nil
        }
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
