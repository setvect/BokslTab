import Foundation

/// Readers never wait for the loader. Only one refresh per key can be queued or running.
final class BackgroundRefreshCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value?
        var updatedAt: TimeInterval = 0
        var requestID: UUID?
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let now: () -> TimeInterval
    private let refreshInterval: TimeInterval
    private let maximumAge: TimeInterval
    private var entries: [Key: Entry] = [:]
    // Set and invoked on the main queue.
    var onRefresh: (() -> Void)?
    private var notificationPending = false

    init(
        queue: DispatchQueue,
        refreshInterval: TimeInterval = 0.5,
        maximumAge: TimeInterval = 5,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.queue = queue
        self.refreshInterval = refreshInterval
        self.maximumAge = maximumAge
        self.now = now
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], now() - entry.updatedAt <= maximumAge else { return nil }
        return entry.value
    }

    func refresh(_ key: Key, load: @escaping () -> Value?) {
        lock.lock()
        var entry = entries[key] ?? Entry()
        let time = now()
        guard entry.requestID == nil,
              entry.value == nil || time - entry.updatedAt >= refreshInterval
        else {
            lock.unlock()
            return
        }
        let requestID = UUID()
        entry.requestID = requestID
        entries[key] = entry
        lock.unlock()

        queue.async { [weak self] in
            guard let self, self.isCurrent(key, requestID: requestID) else { return }
            let value = load()
            self.lock.lock()
            guard var entry = self.entries[key], entry.requestID == requestID else {
                self.lock.unlock()
                return
            }
            entry.requestID = nil
            if let value {
                entry.value = value
                entry.updatedAt = self.now()
            }
            self.entries[key] = entry
            self.lock.unlock()
            if value != nil {
                DispatchQueue.main.async { [weak self] in self?.scheduleNotification() }
            }
        }
    }

    private func scheduleNotification() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            self.onRefresh?()
        }
    }

    func retainOnly(_ keys: Set<Key>) {
        lock.lock()
        entries = entries.filter { keys.contains($0.key) }
        lock.unlock()
    }

    private func isCurrent(_ key: Key, requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.requestID == requestID
    }
}
