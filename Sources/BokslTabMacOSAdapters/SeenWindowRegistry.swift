import BokslTabCore
import CoreGraphics
import Foundation

/// Windows that have been listed while on screen, remembered by CoreGraphics window number.
///
/// A window that moves to a full-screen Space or another desktop drops out of the on-screen CG list,
/// and AX only reports windows of the current Space. Remembering what was already shown keeps such a
/// window switchable: while the window server still has it off screen, it is listed again with its
/// last known title. Only windows seen on screen are remembered, so hidden helper windows that were
/// never rows cannot appear. Used from the main thread only, like the title cache.
final class SeenWindowRegistry {
    struct Entry: Equatable {
        let windowID: UInt32
        let processIdentifier: Int32
        var title: String
        var ownerName: String?
        var isMinimized: Bool
        var lastSeen: UInt64
    }

    static let defaultMaxEntries = 256

    private let maxEntries: Int
    private var entries: [UInt32: Entry] = [:]
    private var clock: UInt64 = 0

    init(maxEntries: Int = defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    var count: Int { entries.count }

    func removeAll() {
        entries.removeAll()
    }

    /// Remembers titled window-server rows. Tab rows share their parent's number and are skipped.
    func recordOnScreen(_ snapshots: [WindowSnapshot]) {
        for snapshot in snapshots {
            let identity = snapshot.identity
            guard identity.source == .coreGraphics,
                  identity.tab == nil,
                  let title = identity.title?.nonBlankCatalogTitle
            else { continue }
            clock &+= 1
            entries[identity.windowID] = Entry(
                windowID: identity.windowID,
                processIdentifier: identity.ownerProcessIdentifier,
                title: title,
                ownerName: snapshot.ownerName,
                isMinimized: false,
                lastSeen: clock
            )
        }
        pruneToMaxEntries()
    }

    /// Gives on-screen rows still without a real title the title they were last listed with.
    ///
    /// AX details can leave a window out: details taken in a full-screen Space hold only the app's
    /// main window, and expired details hold nothing. The title cache keeps one title per app, so of
    /// two maximized windows sharing a frame only one got a title and the other was dropped as its
    /// untitled duplicate. A window's own remembered title keeps both rows.
    func applyRememberedTitles(to snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        snapshots.map { snapshot in
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

    /// Fresh AX details for remembered windows: minimized state, and a newer title when one is known.
    func applyAccessibilityState(_ snapshotsByPID: [Int32: [AccessibilityWindowSnapshot]]) {
        for (processIdentifier, snapshots) in snapshotsByPID {
            for snapshot in snapshots {
                guard let windowID = snapshot.windowID,
                      var entry = entries[windowID],
                      entry.processIdentifier == processIdentifier
                else { continue }
                entry.isMinimized = snapshot.isMinimized
                if let title = snapshot.title?.nonBlankCatalogTitle { entry.title = title }
                entries[windowID] = entry
            }
        }
    }

    /// Remembered windows of the given apps that the window server still has, but not on screen.
    /// Closed windows are forgotten here; minimized ones stay out of the list.
    func offScreenSnapshots(
        processIdentifiers: Set<Int32>,
        excludingWindowIDs: Set<UInt32>,
        windowInfo: (UInt32) -> [String: Any]?
    ) -> [WindowSnapshot] {
        let candidates = entries.values
            .filter { processIdentifiers.contains($0.processIdentifier) && !excludingWindowIDs.contains($0.windowID) }
            .sorted { lhs, rhs in lhs.lastSeen > rhs.lastSeen }

        var snapshots: [WindowSnapshot] = []
        for entry in candidates {
            let info = windowInfo(entry.windowID)
            switch WindowServerPlacement(windowInfo: info, processIdentifier: entry.processIdentifier) {
            case .missing:
                entries.removeValue(forKey: entry.windowID)
            case .onScreen:
                continue
            case .offScreen:
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
        }
        return snapshots
    }

    private func pruneToMaxEntries() {
        guard entries.count > maxEntries else { return }
        let kept = entries.values.sorted { lhs, rhs in lhs.lastSeen > rhs.lastSeen }.prefix(maxEntries)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.windowID, $0) })
    }
}
