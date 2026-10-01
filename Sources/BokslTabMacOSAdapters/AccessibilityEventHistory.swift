import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

struct AccessibilityEventObservedAppDescriptor: Hashable {
    let processIdentifier: Int32
    let ownerName: String?

    init(processIdentifier: Int32, ownerName: String? = nil) {
        self.processIdentifier = processIdentifier
        self.ownerName = ownerName?.nonBlankCatalogTitle
    }
}

struct AccessibilityEventWindowCacheEntry: Equatable {
    let processIdentifier: Int32
    let windowID: UInt32
    let title: String
    let frame: CGRect
    let ownerName: String?
    let source: String
    let updatedAt: Date

    init(
        processIdentifier: Int32,
        windowID: UInt32,
        title: String,
        frame: CGRect,
        ownerName: String? = nil,
        source: String,
        updatedAt: Date
    ) {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.ownerName = ownerName?.nonBlankCatalogTitle
        self.source = source
        self.updatedAt = updatedAt
    }
}

struct AccessibilityEventWindowSnapshotPolicy {
    static func snapshots(
        from entries: [AccessibilityEventWindowCacheEntry],
        eligiblePIDs: Set<Int32>,
        excluding includedSnapshots: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        guard !eligiblePIDs.isEmpty else { return [] }
        let includedWindowKeys = Set(includedSnapshots.map(WindowKey.init(snapshot:)))

        let candidates = entries
            .filter { eligiblePIDs.contains($0.processIdentifier) }
            .filter { entry in
                AccessibilityEventWindowHistoryPolicy.matchesLiveWindowFrame(
                    entry: entry,
                    includedSnapshots: includedSnapshots
                )
            }
            .filter { entry in
                !AccessibilityEventWindowHistoryPolicy.hasSameProjectTitle(
                    entry: entry,
                    snapshots: includedSnapshots
                )
            }
            .filter { entry in
                guard WindowSnapshot.isReasonableWindowBounds(entry.frame),
                      !TabExpandedWindowCatalogPolicy.isPlaceholderTitle(entry.title)
                else { return false }

                let key = WindowKey(entry: entry)
                return !includedWindowKeys.contains(key)
            }

        return AccessibilityEventWindowHistoryPolicy.latestEntriesByProjectTitle(candidates)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { entry in
                WindowSnapshot(
                    identity: WindowIdentity(
                        windowID: entry.windowID,
                        ownerProcessIdentifier: entry.processIdentifier,
                        title: entry.title,
                        source: .accessibilityEvent
                    ),
                    bounds: entry.frame,
                    ownerName: entry.ownerName
                )
            }
    }

    private struct WindowKey: Hashable {
        let processIdentifier: Int32
        let normalizedTitle: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(entry: AccessibilityEventWindowCacheEntry) {
            self.processIdentifier = entry.processIdentifier
            self.normalizedTitle = entry.title.nonBlankCatalogTitle?.lowercased() ?? ""
            self.x = Int(entry.frame.origin.x.rounded())
            self.y = Int(entry.frame.origin.y.rounded())
            self.width = Int(entry.frame.width.rounded())
            self.height = Int(entry.frame.height.rounded())
        }

        init(snapshot: WindowSnapshot) {
            self.processIdentifier = snapshot.identity.ownerProcessIdentifier
            self.normalizedTitle = snapshot.identity.title?.nonBlankCatalogTitle?.lowercased() ?? ""
            self.x = Int(snapshot.bounds.origin.x.rounded())
            self.y = Int(snapshot.bounds.origin.y.rounded())
            self.width = Int(snapshot.bounds.width.rounded())
            self.height = Int(snapshot.bounds.height.rounded())
        }
    }
}

struct AccessibilityEventWindowHistoryPolicy {
    static func shouldPreserve(
        previous: AccessibilityEventWindowCacheEntry,
        currentEntries: [AccessibilityEventWindowCacheEntry]
    ) -> Bool {
        guard !currentEntries.isEmpty else { return false }
        if currentEntries.contains(where: { hasSameProjectTitle($0, previous) }) {
            return false
        }
        let currentSnapshots = currentEntries.map { entry in
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: entry.windowID,
                    ownerProcessIdentifier: entry.processIdentifier,
                    title: entry.title,
                    source: .accessibilityEvent
                ),
                bounds: entry.frame,
                ownerName: entry.ownerName
            )
        }
        return matchesLiveWindowFrame(entry: previous, includedSnapshots: currentSnapshots)
    }

    static func latestEntriesByProjectTitle(
        _ entries: [AccessibilityEventWindowCacheEntry]
    ) -> [AccessibilityEventWindowCacheEntry] {
        var latestByKey: [ProjectTitleKey: AccessibilityEventWindowCacheEntry] = [:]
        for entry in entries {
            let key = ProjectTitleKey(entry)
            guard let existing = latestByKey[key] else {
                latestByKey[key] = entry
                continue
            }
            if entry.updatedAt > existing.updatedAt {
                latestByKey[key] = entry
            }
        }
        return Array(latestByKey.values)
    }

    static func hasSameProjectTitle(
        entry: AccessibilityEventWindowCacheEntry,
        snapshots: [WindowSnapshot]
    ) -> Bool {
        snapshots.contains { snapshot in
            guard snapshot.identity.ownerProcessIdentifier == entry.processIdentifier,
                  let title = snapshot.identity.title
            else { return false }
            return ProjectTitleKey(processIdentifier: entry.processIdentifier, title: entry.title)
                == ProjectTitleKey(processIdentifier: snapshot.identity.ownerProcessIdentifier, title: title)
        }
    }

    static func matchesLiveWindowFrame(
        entry: AccessibilityEventWindowCacheEntry,
        includedSnapshots: [WindowSnapshot]
    ) -> Bool {
        let candidateFrames = includedSnapshots
            .filter { $0.identity.ownerProcessIdentifier == entry.processIdentifier }
            .map(\.bounds)
        return WindowFrameMatchPolicy.bestFrameMatchIndex(
            targetFrame: entry.frame,
            candidateFrames: candidateFrames
        ) != nil
    }

    private static func hasSameProjectTitle(
        _ lhs: AccessibilityEventWindowCacheEntry,
        _ rhs: AccessibilityEventWindowCacheEntry
    ) -> Bool {
        ProjectTitleKey(lhs) == ProjectTitleKey(rhs)
    }

    struct ProjectTitleKey: Hashable {
        let processIdentifier: Int32
        let title: String

        init(_ entry: AccessibilityEventWindowCacheEntry) {
            self.init(processIdentifier: entry.processIdentifier, title: entry.title)
        }

        init(processIdentifier: Int32, title: String) {
            self.processIdentifier = processIdentifier
            self.title = StableWindowTitleKey.normalized(title)
        }
    }
}
