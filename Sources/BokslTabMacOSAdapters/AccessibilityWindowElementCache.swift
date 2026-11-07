import ApplicationServices
import Foundation

/// AX handles of windows, by owning process and CoreGraphics window number.
///
/// AX lists only the windows of the current Space, but a handle stays valid after its window moves to
/// another desktop or into full screen. Raising that handle makes the owning app bring the window
/// forward itself, which is what reliably makes macOS follow it to its Space. Handles are recorded
/// whenever a window is seen through AX and checked against the window number before use.
final class AccessibilityWindowElementCache: @unchecked Sendable {
    static let defaultMaxEntries = 512

    private struct Key: Hashable {
        let processIdentifier: Int32
        let windowID: UInt32
    }

    private struct Entry {
        let element: AXUIElement
        let lastSeen: UInt64
    }

    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(maxEntries: Int = defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func record(_ element: AXUIElement, windowID: UInt32, processIdentifier: Int32) {
        lock.lock()
        defer { lock.unlock() }
        clock &+= 1
        entries[Key(processIdentifier: processIdentifier, windowID: windowID)] = Entry(element: element, lastSeen: clock)
        guard entries.count > maxEntries else { return }
        let kept = entries.sorted { lhs, rhs in lhs.value.lastSeen > rhs.value.lastSeen }.prefix(maxEntries)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    func element(windowID: UInt32, processIdentifier: Int32) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(processIdentifier: processIdentifier, windowID: windowID)]?.element
    }

    func remove(windowID: UInt32, processIdentifier: Int32) {
        lock.lock()
        entries.removeValue(forKey: Key(processIdentifier: processIdentifier, windowID: windowID))
        lock.unlock()
    }

    func retainOnly(_ processIdentifiers: Set<Int32>) {
        lock.lock()
        entries = entries.filter { processIdentifiers.contains($0.key.processIdentifier) }
        lock.unlock()
    }
}
