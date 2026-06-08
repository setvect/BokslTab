import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSMRUOrderingProvider: SwitcherMRUOrderingProviding, SwitcherMRUHistoryRecording {
    private let windowInfoLister: CGWindowInfoListing
    private let history: MRUItemHistory
    private var activationObserver: NSObjectProtocol?

    public convenience init() {
        self.init(windowInfoLister: SystemCGWindowInfoLister())
    }

    init(
        windowInfoLister: CGWindowInfoListing,
        initialRecentItemIDs: [String] = []
    ) {
        self.windowInfoLister = windowInfoLister
        self.history = MRUItemHistory(initialItemIDs: initialRecentItemIDs)
        self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordFrontmostSnapshotIfAvailable()
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    public func orderingContext(for mode: SwitcherMode, items: [SwitcherItem]) -> SwitcherMRUOrderingContext {
        guard !items.isEmpty else {
            return .fallback(reason: "empty-items")
        }

        guard let infoList = windowInfoLister.windowInfoList() else {
            return .fallback(reason: "cg-window-list-unavailable")
        }

        let projectionIndex = MRUItemProjectionIndex(items: items)
        let snapshots = infoList.compactMap(MRUWindowSnapshot.init(windowInfo:))
        recordFrontmostSnapshot(snapshots.first)

        let frontToBackItemIDs = MRUOrderingDeduplicator.uniqueIDs(
            snapshots.flatMap(\.projectedItemIDs).compactMap { projectionIndex.itemID(forProjectedID: $0) }
        )
        let historyItemIDs = MRUOrderingDeduplicator.uniqueIDs(
            history.orderedItemIDs().compactMap { projectionIndex.itemID(forProjectedID: $0) }
        )
        let orderedItemIDs = MRUOrderingDeduplicator.uniqueIDs(historyItemIDs + frontToBackItemIDs)
        let firstSnapshotID = snapshots.first?.windowID ?? "none"
        let firstSnapshotMatched = snapshots.first
            .flatMap { projectionIndex.itemID(forProjectedID: $0.windowID) } != nil
        BokslTabDiagnosticLog.write(
            "mru.cg raw=\(infoList.count) snapshots=\(snapshots.count) items=\(items.count) first=\(firstSnapshotID) firstMatched=\(firstSnapshotMatched) frontMatches=\(frontToBackItemIDs.prefix(8).joined(separator: ",")) historyMatches=\(historyItemIDs.prefix(8).joined(separator: ","))"
        )

        guard !orderedItemIDs.isEmpty else {
            return .fallback(reason: "no-matching-front-to-back-windows")
        }

        return SwitcherMRUOrderingContext(
            orderedItemIDs: orderedItemIDs,
            currentItemID: frontToBackItemIDs.first ?? historyItemIDs.first,
            sourceDescription: sourceDescription(historyMatchedItemCount: historyItemIDs.count)
        )
    }

    public func recordActivatedItem(_ item: SwitcherItem) {
        history.record(item.mruProjectedIDs)
    }

    public func recordActivatedApp(_ app: AppIdentity) {
        history.record([SwitcherItem.appID(processIdentifier: app.processIdentifier)])
    }

    private func recordFrontmostSnapshotIfAvailable() {
        guard let infoList = windowInfoLister.windowInfoList() else { return }
        recordFrontmostSnapshot(infoList.compactMap(MRUWindowSnapshot.init(windowInfo:)).first)
    }

    private func recordFrontmostSnapshot(_ snapshot: MRUWindowSnapshot?) {
        guard let snapshot else { return }
        history.record(snapshot.projectedItemIDs)
    }

    private func sourceDescription(historyMatchedItemCount: Int) -> String {
        historyMatchedItemCount > 1
            ? "workspace-activation-history+cg-window-list-front-to-back"
            : "cg-window-list-front-to-back"
    }
}

protocol CGWindowInfoListing {
    func windowInfoList() -> [[String: Any]]?
}

private struct SystemCGWindowInfoLister: CGWindowInfoListing {
    func windowInfoList() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    }
}

final class MRUItemHistory {
    private static let maximumItemCount = 100

    private let lock = NSLock()
    private var itemIDs: [String]

    init(initialItemIDs: [String] = []) {
        self.itemIDs = Array(MRUOrderingDeduplicator.uniqueIDs(initialItemIDs).prefix(Self.maximumItemCount))
    }

    func record(_ itemIDs: [String]) {
        let uniqueItemIDs = MRUOrderingDeduplicator.uniqueIDs(itemIDs)
        guard !uniqueItemIDs.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        self.itemIDs.removeAll { uniqueItemIDs.contains($0) }
        self.itemIDs.insert(contentsOf: uniqueItemIDs, at: 0)
        if self.itemIDs.count > Self.maximumItemCount {
            self.itemIDs = Array(self.itemIDs.prefix(Self.maximumItemCount))
        }
    }

    func orderedItemIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return itemIDs
    }
}

struct MRUItemProjectionIndex {
    private let itemIDByProjectedID: [String: String]

    init(items: [SwitcherItem]) {
        var exactItemIDs: [String: String] = [:]
        var unambiguousAliases: [String: String] = [:]
        var ambiguousAliases = Set<String>()

        for item in items {
            exactItemIDs[item.id] = item.id

            switch item.kind {
            case .app:
                unambiguousAliases[item.id] = item.id
            case .window(let window):
                guard let tab = window.tab, tab.isSelected else { continue }
                let parentWindowID = SwitcherItem.windowID(
                    windowID: tab.parentWindowID,
                    ownerProcessIdentifier: window.ownerProcessIdentifier
                )
                if let existing = unambiguousAliases[parentWindowID], existing != item.id {
                    unambiguousAliases.removeValue(forKey: parentWindowID)
                    ambiguousAliases.insert(parentWindowID)
                } else if !ambiguousAliases.contains(parentWindowID) {
                    unambiguousAliases[parentWindowID] = item.id
                }
            }
        }

        ambiguousAliases.forEach { unambiguousAliases.removeValue(forKey: $0) }
        self.itemIDByProjectedID = exactItemIDs.merging(unambiguousAliases) { exact, _ in exact }
    }

    func itemID(forProjectedID projectedID: String) -> String? {
        itemIDByProjectedID[projectedID]
    }
}

struct MRUOrderingDeduplicator {
    static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }
}

struct MRUWindowSnapshot {
    let windowID: String
    let ownerProcessIdentifier: Int32

    var projectedItemIDs: [String] {
        [
            windowID,
            SwitcherItem.appID(processIdentifier: ownerProcessIdentifier)
        ]
    }

    init?(windowInfo: [String: Any]) {
        guard let layerNumber = windowInfo[kCGWindowLayer as String] as? NSNumber,
              layerNumber.intValue == 0,
              let pidNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
              let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber,
              let bounds = CGRect.fromMRUWindowInfo(windowInfo[kCGWindowBounds as String]),
              MRUWindowSnapshot.isReasonableWindowBounds(bounds)
        else { return nil }

        ownerProcessIdentifier = pidNumber.int32Value
        windowID = SwitcherItem.windowID(
            windowID: windowNumber.uint32Value,
            ownerProcessIdentifier: ownerProcessIdentifier
        )
    }

    static func isReasonableWindowBounds(_ bounds: CGRect) -> Bool {
        bounds.width >= 40 && bounds.height >= 40
    }
}

private extension CGRect {
    static func fromMRUWindowInfo(_ rawBounds: Any?) -> CGRect? {
        guard let dictionary = rawBounds as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}
