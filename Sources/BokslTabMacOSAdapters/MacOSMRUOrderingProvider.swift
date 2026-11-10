import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSMRUOrderingProvider: SwitcherMRUOrderingProviding, SwitcherMRUHistoryRecording {
    private let windowInfoLister: CGWindowInfoListing
    private let order: MRUOrderList
    /// Rows of the last full list. An app activation between lists moves the topmost of these to the
    /// front, so a helper window above the real one (Chrome's full-screen toolbar) is not mistaken for it.
    private var knownRowIDs = Set<String>()
    private var activationObserver: NSObjectProtocol?

    public convenience init() {
        self.init(windowInfoLister: SystemCGWindowInfoLister())
    }

    /// Also follows window focus inside observed apps: a project tab clicked in IntelliJ moves to the
    /// front of the order although no app was activated.
    public convenience init(accessibility: MacOSAccessibilityService) {
        self.init()
        accessibility.windowFocusHandler = { [weak self] windowID, processIdentifier in
            DispatchQueue.main.async {
                // An app in the background can change its focused window too; that is not a use.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else { return }
                self?.recordFocusedWindow(windowID: windowID, processIdentifier: processIdentifier)
            }
        }
    }

    init(
        windowInfoLister: CGWindowInfoListing,
        initialRecentItemIDs: [String] = []
    ) {
        self.windowInfoLister = windowInfoLister
        self.order = MRUOrderList(initialItemIDs: initialRecentItemIDs)
        self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.recordActivatedApplication(processIdentifier: app?.processIdentifier)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// One list holds the order of everything: a picked row moves to the front, and each time the full
    /// list opens it is corrected by the windows' real stacking and saved back. Switches made without
    /// BokslTab (clicks, the Dock) reach the list through that correction, and every row keeps a place.
    public func orderingContext(for mode: SwitcherMode, items: [SwitcherItem]) -> SwitcherMRUOrderingContext {
        guard !items.isEmpty else {
            return .fallback(reason: "empty-items")
        }

        guard let infoList = windowInfoLister.windowInfoList() else {
            return .fallback(reason: "cg-window-list-unavailable")
        }

        let projectionIndex = MRUItemProjectionIndex(items: items)
        let snapshots = infoList.compactMap(MRUWindowSnapshot.init(windowInfo:))
        moveFrontmostToFront(snapshots) { snapshot in
            snapshot.projectedItemIDs.contains { projectionIndex.itemID(forProjectedID: $0) != nil }
        }

        let frontToBackItemIDs = MRUOrderingDeduplicator.uniqueIDs(
            snapshots.flatMap(\.projectedItemIDs).compactMap { projectionIndex.itemID(forProjectedID: $0) }
        )
        let recordedItemIDs = MRUOrderingDeduplicator.uniqueIDs(
            order.itemIDs().compactMap { projectionIndex.itemID(forProjectedID: $0) }
        )
        let merged = MRUOrderMerger.merge(frontToBackItemIDs: frontToBackItemIDs, recordedItemIDs: recordedItemIDs)
        let firstSnapshotID = snapshots.first?.windowID ?? "none"
        let firstSnapshotMatched = snapshots.first
            .flatMap { projectionIndex.itemID(forProjectedID: $0.windowID) } != nil

        guard !merged.orderedItemIDs.isEmpty else {
            return .fallback(reason: "no-matching-front-to-back-windows")
        }

        // A row seen for the first time and not on screen has no place yet: it goes last, by title.
        let placedIDs = Set(merged.orderedItemIDs)
        let unrecordedItemIDs = items.sortedForSwitcher().map(\.id).filter { !placedIDs.contains($0) }
        let orderedItemIDs = merged.orderedItemIDs + unrecordedItemIDs
        BokslTabDiagnosticLog.write(
            "mru.cg raw=\(infoList.count) snapshots=\(snapshots.count) items=\(items.count) first=\(firstSnapshotID) firstMatched=\(firstSnapshotMatched) frontMatches=\(frontToBackItemIDs.prefix(8).joined(separator: ",")) historyMatches=\(recordedItemIDs.prefix(8).joined(separator: ",")) historyOnly=\(merged.offScreenItemIDs.count) unrecorded=\(unrecordedItemIDs.count)"
        )
        if mode == .allAppsAndWindows {
            save(orderedItemIDs: orderedItemIDs, items: items)
        }

        return SwitcherMRUOrderingContext(
            orderedItemIDs: orderedItemIDs,
            currentItemID: frontToBackItemIDs.first ?? recordedItemIDs.first,
            sourceDescription: sourceDescription(offScreenItemCount: merged.offScreenItemIDs.count)
        )
    }

    public func recordActivatedItem(_ item: SwitcherItem) {
        order.moveToFront(item.mruProjectedIDs)
    }

    public func recordActivatedApp(_ app: AppIdentity) {
        order.moveToFront([SwitcherItem.appID(processIdentifier: app.processIdentifier)])
    }

    func recordFocusedWindow(windowID: UInt32, processIdentifier: Int32) {
        order.moveToFront([
            SwitcherItem.windowID(windowID: windowID, ownerProcessIdentifier: processIdentifier),
            SwitcherItem.appID(processIdentifier: processIdentifier)
        ])
    }

    /// An app came to the front without a row being picked (a click, the Dock). Its topmost window
    /// moves to the front of the order. Only that app's windows count: when BokslTab's own panel is
    /// the app that activated, a window that merely lies below a newly appeared one was not used.
    func recordActivatedApplication(processIdentifier: Int32?) {
        guard let infoList = windowInfoLister.windowInfoList() else { return }
        var snapshots = infoList.compactMap(MRUWindowSnapshot.init(windowInfo:))
        if let processIdentifier {
            snapshots = snapshots.filter { $0.ownerProcessIdentifier == processIdentifier }
        }
        let knownRowIDs = knownRowIDs
        moveFrontmostToFront(snapshots) { snapshot in
            knownRowIDs.contains(snapshot.windowID)
        }
    }

    /// The topmost window is not always a row: Chrome keeps a toolbar window above a full-screen
    /// window. The topmost row, the window the user is in, moves to the front right behind it.
    private func moveFrontmostToFront(_ snapshots: [MRUWindowSnapshot], isRow: (MRUWindowSnapshot) -> Bool) {
        let topmostRow = snapshots.first(where: isRow)
        order.moveToFront((snapshots.first?.projectedItemIDs ?? []) + (topmostRow?.projectedItemIDs ?? []))
    }

    /// Only the full list is saved: the active-app list holds one app's windows, and writing it back
    /// would put all of them ahead of every other app.
    private func save(orderedItemIDs: [String], items: [SwitcherItem]) {
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        order.moveToFront(orderedItemIDs.flatMap { id -> [String] in
            // A tab row's number changes with its parent window; its title alias keeps its place.
            [id] + (itemsByID[id]?.mruProjectedIDs.filter(SwitcherItem.isStableTitleAliasID) ?? [])
        })
        knownRowIDs = Set(orderedItemIDs)
    }

    private func sourceDescription(offScreenItemCount: Int) -> String {
        offScreenItemCount > 0
            ? "cg-window-list-front-to-back+activation-history"
            : "cg-window-list-front-to-back"
    }
}

/// The window server's stacking already reflects every focus change, including clicks the order list
/// never sees, so it alone orders the rows on screen. The list only places rows that are not on screen
/// (other Spaces, full screen, hidden apps, unselected tabs).
///
/// Such a row goes right below the lowest on-screen row that the list says is newer. A row raised by a
/// click, or together with its app, sits higher than the list knows; anchoring to the newer rows keeps
/// such a row from pulling off-screen rows up with it. On-screen rows the list never saw decide nothing.
enum MRUOrderMerger {
    struct Result: Equatable {
        let orderedItemIDs: [String]
        let offScreenItemIDs: [String]
    }

    static func merge(frontToBackItemIDs: [String], recordedItemIDs: [String]) -> Result {
        let onScreenIDs = MRUOrderingDeduplicator.uniqueIDs(frontToBackItemIDs)
        let stackIndexByID = Dictionary(uniqueKeysWithValues: onScreenIDs.enumerated().map { ($1, $0) })

        var leadingOffScreenIDs: [String] = []
        var offScreenIDsBelowStackIndex: [Int: [String]] = [:]
        var offScreenIDs: [String] = []
        var lowestNewerStackIndex: Int?

        for id in MRUOrderingDeduplicator.uniqueIDs(recordedItemIDs) {
            if let stackIndex = stackIndexByID[id] {
                lowestNewerStackIndex = max(lowestNewerStackIndex ?? stackIndex, stackIndex)
                continue
            }
            offScreenIDs.append(id)
            if let lowestNewerStackIndex {
                offScreenIDsBelowStackIndex[lowestNewerStackIndex, default: []].append(id)
            } else {
                leadingOffScreenIDs.append(id)
            }
        }

        let orderedIDs = leadingOffScreenIDs + onScreenIDs.indices.flatMap { index in
            [onScreenIDs[index]] + (offScreenIDsBelowStackIndex[index] ?? [])
        }
        return Result(orderedItemIDs: orderedIDs, offScreenItemIDs: offScreenIDs)
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

/// Row IDs from most to least recently used. Besides rows it holds title aliases, app IDs and windows
/// that are not rows; those take no part in ordering unless a later list maps them to a row.
final class MRUOrderList {
    private static let maximumItemCount = 512

    private let lock = NSLock()
    private var ids: [String]

    init(initialItemIDs: [String] = []) {
        self.ids = Array(MRUOrderingDeduplicator.uniqueIDs(initialItemIDs).prefix(Self.maximumItemCount))
    }

    func itemIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    /// The given IDs take the front in their order; the rest keep their relative order behind them.
    func moveToFront(_ itemIDs: [String]) {
        let front = MRUOrderingDeduplicator.uniqueIDs(itemIDs)
        guard !front.isEmpty else { return }
        let frontSet = Set(front)

        lock.lock()
        defer { lock.unlock() }
        ids = Array((front + ids.filter { !frontSet.contains($0) }).prefix(Self.maximumItemCount))
    }
}

struct MRUItemProjectionIndex {
    private let itemIDByProjectedID: [String: String]

    init(items: [SwitcherItem]) {
        var exactItemIDs: [String: String] = [:]
        var unambiguousAliases: [String: String] = [:]
        var ambiguousAliases = Set<String>()

        func registerAlias(_ aliasID: String, for itemID: String) {
            if let existing = unambiguousAliases[aliasID], existing != itemID {
                unambiguousAliases.removeValue(forKey: aliasID)
                ambiguousAliases.insert(aliasID)
            } else if !ambiguousAliases.contains(aliasID) {
                unambiguousAliases[aliasID] = itemID
            }
        }

        for item in items {
            exactItemIDs[item.id] = item.id

            item.mruProjectedIDs
                .filter(SwitcherItem.isStableTitleAliasID)
                .forEach { registerAlias($0, for: item.id) }

            guard case .window(let window) = item.kind,
                  let tab = window.tab,
                  tab.isSelected
            else { continue }

            registerAlias(
                SwitcherItem.windowID(
                    windowID: tab.parentWindowID,
                    ownerProcessIdentifier: window.ownerProcessIdentifier
                ),
                for: item.id
            )
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
