import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

final class WindowTitleCache {
    struct Entry {
        let ownerName: String?
        let title: String
    }

    static let minimumCacheableWidth: CGFloat = 200
    static let minimumCacheableHeight: CGFloat = 200
    static let defaultMaxEntries = 64

    private let maxEntries: Int
    private var entriesByPID: [Int32: Entry] = [:]
    private var recencyByPID: [Int32: UInt64] = [:]
    private var recencyClock: UInt64 = 0

    init(maxEntries: Int = defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    func record(_ snapshots: [WindowSnapshot]) {
        var recordedPIDs = Set<Int32>()
        for snapshot in snapshots {
            let processIdentifier = snapshot.identity.ownerProcessIdentifier
            guard !recordedPIDs.contains(processIdentifier),
                  let title = snapshot.identity.title?.nonBlankCatalogTitle,
                  Self.isCacheable(snapshot)
            else { continue }

            entriesByPID[processIdentifier] = Entry(
                ownerName: snapshot.ownerName,
                title: title
            )
            touch(processIdentifier)
            recordedPIDs.insert(processIdentifier)
            BokslTabDiagnosticLog.debug(
                "window-catalog.cache.record pid=\(processIdentifier) sourceWindow=\(snapshot.identity.windowID) title=\(title.catalogDiagnosticValue) bounds=\(snapshot.bounds.catalogDiagnosticDescription)"
            )
        }
    }

    func applyCachedTitles(to snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        var updatedSnapshots = snapshots
        let weakCacheableIndices = updatedSnapshots.indices.filter { index in
            WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(updatedSnapshots[index])
                && Self.hasCacheableGeometry(updatedSnapshots[index].bounds)
        }
        let weakIndicesByPID = Dictionary(grouping: weakCacheableIndices) { index in
            updatedSnapshots[index].identity.ownerProcessIdentifier
        }

        for (processIdentifier, weakIndices) in weakIndicesByPID {
            guard let targetIndex = weakIndices.max(by: {
                updatedSnapshots[$0].bounds.area < updatedSnapshots[$1].bounds.area
            }),
                  let entry = cachedEntry(
                      processIdentifier: processIdentifier,
                      appDisplayName: updatedSnapshots[targetIndex].ownerName ?? ""
                  )
            else { continue }

            updatedSnapshots[targetIndex] = updatedSnapshots[targetIndex].withTitle(entry.title)
            BokslTabDiagnosticLog.debug(
                "window-catalog.cache.apply pid=\(processIdentifier) targetWindow=\(updatedSnapshots[targetIndex].identity.windowID) title=\(entry.title.catalogDiagnosticValue) bounds=\(updatedSnapshots[targetIndex].bounds.catalogDiagnosticDescription)"
            )
        }

        return updatedSnapshots
    }

    static func isCacheable(_ snapshot: WindowSnapshot) -> Bool {
        guard snapshot.identity.title?.nonBlankCatalogTitle != nil else { return false }
        return hasCacheableGeometry(snapshot.bounds)
    }

    private static func hasCacheableGeometry(_ bounds: CGRect) -> Bool {
        bounds.width >= minimumCacheableWidth
            && bounds.height >= minimumCacheableHeight
    }

    private static func matchesCachedOwner(_ cachedOwnerName: String?, appDisplayName: String) -> Bool {
        guard let cachedOwnerName,
              let appDisplayName = appDisplayName.nonBlankCatalogTitle
        else { return true }
        return cachedOwnerName.localizedCaseInsensitiveCompare(appDisplayName) == .orderedSame
    }

    private func cachedEntry(processIdentifier: Int32, appDisplayName: String) -> Entry? {
        guard let entry = entriesByPID[processIdentifier],
              Self.matchesCachedOwner(entry.ownerName, appDisplayName: appDisplayName)
        else { return nil }
        touch(processIdentifier)
        return entry
    }

    private func touch(_ processIdentifier: Int32) {
        recencyClock &+= 1
        recencyByPID[processIdentifier] = recencyClock
        pruneToMaxEntries()
    }

    private func pruneToMaxEntries() {
        while entriesByPID.count > maxEntries,
              let evictedPID = recencyByPID.min(by: { $0.value < $1.value })?.key {
            entriesByPID.removeValue(forKey: evictedPID)
            recencyByPID.removeValue(forKey: evictedPID)
            BokslTabDiagnosticLog.debug("window-catalog.cache.evict pid=\(evictedPID) reason=max-entries-\(maxEntries)")
        }
    }
}
