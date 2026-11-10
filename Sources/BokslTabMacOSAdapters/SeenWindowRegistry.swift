import BokslTabCore
import CoreGraphics
import Foundation

/// Every window BokslTab has seen, remembered by CoreGraphics window number with its last title.
///
/// The on-screen CG list and AX only report windows of the visible Spaces, and an unselected native
/// tab (an IntelliJ project, a Finder tab) is a window shown on no Space at all. A window seen once
/// stays a row from here: while the window server still has it, it is listed again under the same
/// number. That number is the row's identity everywhere, so its place in the recent-use order and its
/// title follow the window, not a guess from its title or position.
///
/// Only windows that were rows on screen or an observed app's own windows are remembered, so helper
/// windows that were never rows cannot appear. Fed from the main thread and the AX worker queue.
final class SeenWindowRegistry: @unchecked Sendable {
    struct Entry: Equatable {
        let windowID: UInt32
        let processIdentifier: Int32
        var title: String
        /// Title of the tab that stood for this window while it was selected in a native tab group.
        var tabTitle: String?
        var ownerName: String?
        var isMinimized: Bool
        var lastSeen: UInt64

        /// What a tab bar may call this window: its tab's title, or the project part of its own title.
        var tabKeys: Set<String> {
            Set([title, tabTitle].compactMap { $0 }.map(StableWindowTitleKey.normalized))
        }
    }

    static let defaultMaxEntries = 256

    private let maxEntries: Int
    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var clock: UInt64 = 0
    private var expectedTabTitleByPID: [Int32: (title: String, expiresAt: TimeInterval)] = [:]

    init(maxEntries: Int = defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        expectedTabTitleByPID.removeAll()
        lock.unlock()
    }

    func retainOnly(_ processIdentifiers: Set<Int32>) {
        lock.lock()
        entries = entries.filter { processIdentifiers.contains($0.value.processIdentifier) }
        expectedTabTitleByPID = expectedTabTitleByPID.filter { processIdentifiers.contains($0.key) }
        lock.unlock()
    }

    /// How long a pressed tab's window may take to come on screen.
    static let expectedTabWindowTimeout: TimeInterval = 5

    /// A tab row was just pressed. The window that comes on screen for it has never been seen, and
    /// right then the app is usually too busy to say what it is. Its tab title is known, though.
    func expectWindow(forTabTitled title: String, processIdentifier: Int32, now: TimeInterval) {
        guard let title = TabTitlePolicy.usableTitle(title) else { return }
        lock.lock()
        expectedTabTitleByPID[processIdentifier] = (title, now + Self.expectedTabWindowTimeout)
        lock.unlock()
    }

    /// Names the window that appeared for a pressed tab: the app's one on-screen window that has no
    /// title and was never seen. Without a name it could not claim its own tab, and the list would
    /// show the project twice, as an untitled window and as that tab.
    func applyExpectedTabTitles(to snapshots: [WindowSnapshot], now: TimeInterval) -> [WindowSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        expectedTabTitleByPID = expectedTabTitleByPID.filter { $0.value.expiresAt > now }
        guard !expectedTabTitleByPID.isEmpty else { return snapshots }

        var named = snapshots
        for (processIdentifier, expected) in expectedTabTitleByPID {
            let unknownIndices = named.indices.filter { index in
                let identity = named[index].identity
                return identity.ownerProcessIdentifier == processIdentifier
                    && identity.source == .coreGraphics
                    && identity.tab == nil
                    && identity.title?.nonBlankCatalogTitle == nil
                    && entries[identity.windowID] == nil
            }
            guard unknownIndices.count == 1, let index = unknownIndices.first else { continue }
            named[index] = named[index].withTitle(expected.title)
            remember(
                windowID: named[index].identity.windowID,
                processIdentifier: processIdentifier,
                title: expected.title,
                ownerName: named[index].ownerName,
                isMinimized: false
            )
            entries[named[index].identity.windowID]?.tabTitle = expected.title
            expectedTabTitleByPID.removeValue(forKey: processIdentifier)
        }
        return named
    }

    /// Remembers titled window-server rows. Tab rows share their parent's number and are skipped.
    func recordOnScreen(_ snapshots: [WindowSnapshot]) {
        lock.lock()
        defer { lock.unlock() }
        for snapshot in snapshots {
            let identity = snapshot.identity
            guard identity.source == .coreGraphics,
                  identity.tab == nil,
                  let title = identity.title?.nonBlankCatalogTitle
            else { continue }
            remember(
                windowID: identity.windowID,
                processIdentifier: identity.ownerProcessIdentifier,
                title: title,
                ownerName: snapshot.ownerName,
                isMinimized: false
            )
        }
        pruneToMaxEntries()
    }

    /// Remembers a window an app itself reported through AX, such as the project window that just
    /// took focus inside a tab group. It may never have been a row while the list was open.
    func record(windowID: UInt32, processIdentifier: Int32, title: String, ownerName: String?, isMinimized: Bool) {
        guard let title = title.nonBlankCatalogTitle else { return }
        lock.lock()
        defer { lock.unlock() }
        remember(
            windowID: windowID,
            processIdentifier: processIdentifier,
            title: title,
            ownerName: ownerName,
            isMinimized: isMinimized
        )
        pruneToMaxEntries()
    }

    /// Gives on-screen rows still without a real title the title they were last seen with.
    ///
    /// AX details can leave a window out: details taken in another Space or before a tab switch do
    /// not hold the window now on screen. Its own remembered title keeps the row correct until fresh
    /// details arrive, and keeps a same-frame sibling from being dropped as an untitled duplicate.
    func applyRememberedTitles(to snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.map { snapshot in
            let identity = snapshot.identity
            guard identity.source == .coreGraphics,
                  identity.tab == nil,
                  WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(snapshot),
                  let entry = entries[identity.windowID],
                  entry.processIdentifier == identity.ownerProcessIdentifier
            else { return snapshot }
            BokslTabDiagnosticLog.debug(
                "window-catalog.remembered-title cgWindow=\(identity.windowID) pid=\(identity.ownerProcessIdentifier) title=\(entry.title.catalogDiagnosticValue)"
            )
            return snapshot.withTitle(entry.title)
        }
    }

    /// AX details for remembered windows: minimized state, a newer title, and the selected tab's title.
    func applyAccessibilityState(_ snapshotsByPID: [Int32: [AccessibilityWindowSnapshot]]) {
        lock.lock()
        defer { lock.unlock() }
        for (processIdentifier, snapshots) in snapshotsByPID {
            for snapshot in snapshots {
                guard let windowID = snapshot.windowID,
                      var entry = entries[windowID],
                      entry.processIdentifier == processIdentifier
                else { continue }
                entry.isMinimized = snapshot.isMinimized
                if let title = snapshot.title?.nonBlankCatalogTitle { entry.title = title }
                if let tabTitle = snapshot.tabs.first(where: \.isSelected)?.title,
                   let usable = TabTitlePolicy.usableTitle(tabTitle) {
                    entry.tabTitle = usable
                }
                entries[windowID] = entry
            }
        }
    }

    /// What the tab bars of an app may call the given remembered windows.
    func tabKeys(windowIDs: [UInt32], processIdentifier: Int32) -> [UInt32: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        var keysByWindowID: [UInt32: Set<String>] = [:]
        for windowID in windowIDs {
            guard let entry = entries[windowID], entry.processIdentifier == processIdentifier else { continue }
            keysByWindowID[windowID] = entry.tabKeys
        }
        return keysByWindowID
    }

    /// Remembered windows of the given apps that still exist but are not on screen.
    ///
    /// A window on another desktop or in a full-screen Space is listed. A window shown on no Space is
    /// listed only when `isUnselectedTab` recognizes it in a tab bar; otherwise it is minimized, hidden
    /// with its app, or closed without being destroyed. Destroyed windows are forgotten here.
    func offScreenSnapshots(
        processIdentifiers: Set<Int32>,
        excludingWindowIDs: Set<UInt32>,
        windowInfo: (UInt32) -> [String: Any]?,
        isUnselectedTab: (Entry) -> Bool = { _ in false }
    ) -> [WindowSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let candidates = entries.values
            .filter { processIdentifiers.contains($0.processIdentifier) && !excludingWindowIDs.contains($0.windowID) }
            .sorted { lhs, rhs in lhs.lastSeen > rhs.lastSeen }

        var snapshots: [WindowSnapshot] = []
        for entry in candidates {
            let info = windowInfo(entry.windowID)
            switch WindowServerPlacement(windowInfo: info, processIdentifier: entry.processIdentifier) {
            case .missing:
                entries.removeValue(forKey: entry.windowID)
                continue
            case .onScreen:
                continue
            case .orderedOut:
                guard isUnselectedTab(entry) else { continue }
            case .offScreen:
                break
            }
            guard !entry.isMinimized,
                  let info,
                  let current = WindowSnapshot.parse(windowInfo: info).snapshot
            else { continue }
            snapshots.append(
                WindowSnapshot(
                    identity: WindowIdentity(
                        windowID: entry.windowID,
                        ownerProcessIdentifier: entry.processIdentifier,
                        title: entry.title
                    ),
                    bounds: current.bounds,
                    ownerName: entry.ownerName ?? current.ownerName
                )
            )
        }
        return snapshots
    }

    private func remember(
        windowID: UInt32,
        processIdentifier: Int32,
        title: String,
        ownerName: String?,
        isMinimized: Bool
    ) {
        clock &+= 1
        let previous = entries[windowID].flatMap { $0.processIdentifier == processIdentifier ? $0 : nil }
        entries[windowID] = Entry(
            windowID: windowID,
            processIdentifier: processIdentifier,
            title: title,
            tabTitle: previous?.tabTitle,
            ownerName: ownerName ?? previous?.ownerName,
            isMinimized: isMinimized,
            lastSeen: clock
        )
    }

    private func pruneToMaxEntries() {
        guard entries.count > maxEntries else { return }
        let kept = entries.values.sorted { lhs, rhs in lhs.lastSeen > rhs.lastSeen }.prefix(maxEntries)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.windowID, $0) })
    }
}
