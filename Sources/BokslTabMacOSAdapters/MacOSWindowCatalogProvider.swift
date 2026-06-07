import ApplicationServices
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSWindowCatalogProvider: WindowCatalogProviding {
    private let titleCache = WindowTitleCache()

    public init() {}

    public func windowsForAllApps() -> [WindowIdentity] {
        currentOnScreenWindows(augmentingWithAccessibilityFor: [])
    }

    public func windowsForAllApps(including apps: [AppIdentity]) -> [WindowIdentity] {
        currentOnScreenWindows(augmentingWithAccessibilityFor: apps)
    }

    public func windows(for app: AppIdentity) -> [WindowIdentity] {
        currentOnScreenWindows(augmentingWithAccessibilityFor: [])
            .filter { $0.ownerProcessIdentifier == app.processIdentifier }
    }

    private func currentOnScreenWindows(augmentingWithAccessibilityFor apps: [AppIdentity]) -> [WindowIdentity] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            BokslTabDiagnosticLog.write("window-catalog.cg unavailable")
            return []
        }

        let parseResults = infoList.map(WindowSnapshot.parse(windowInfo:))
        let snapshots = parseResults.compactMap(\.snapshot)
        let rejectionSummary = WindowSnapshotParseResult.rejectionSummary(parseResults)
        BokslTabDiagnosticLog.write(
            "window-catalog.cg raw=\(infoList.count) candidates=\(snapshots.count) rejected=\(rejectionSummary)"
        )
        snapshots.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.cg.candidate \(snapshot.diagnosticDescription)")
        }

        let enrichedSnapshots = enrichTitlesFromAccessibilityIfPossible(snapshots)
        let cachedEnrichedSnapshots = titleCache.applyCachedTitles(to: enrichedSnapshots)
        let filteredSnapshots = filterLikelyDuplicateUntitledSnapshots(cachedEnrichedSnapshots)
        let axOnlySnapshots = accessibilityOnlySnapshotsForAppsWithoutCGWindows(
            apps,
            includedSnapshots: filteredSnapshots
        )
        let liveSnapshots = filteredSnapshots + axOnlySnapshots
        titleCache.record(liveSnapshots)
        let cachedSnapshots = cachedTitleSnapshotsForAppsWithoutWindows(
            apps,
            includedSnapshots: liveSnapshots
        )
        let resultSnapshots = liveSnapshots + cachedSnapshots
        BokslTabDiagnosticLog.write(
            "window-catalog.result candidates=\(snapshots.count) enriched=\(enrichedSnapshots.count) cgIncluded=\(filteredSnapshots.count) axOnly=\(axOnlySnapshots.count) cached=\(cachedSnapshots.count) included=\(resultSnapshots.count)"
        )
        resultSnapshots.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.include \(snapshot.diagnosticDescription)")
        }
        return resultSnapshots.map(\.identity)
    }

    private func enrichTitlesFromAccessibilityIfPossible(_ snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        guard AXIsProcessTrusted() else {
            BokslTabDiagnosticLog.write("window-catalog.ax skipped reason=accessibility-untrusted snapshots=\(snapshots.count)")
            return snapshots
        }

        let axSnapshotsByPID = accessibilityWindowSnapshotsByPID(
            Set(snapshots.map { $0.identity.ownerProcessIdentifier })
        )
        guard !axSnapshotsByPID.isEmpty else {
            BokslTabDiagnosticLog.write("window-catalog.ax empty snapshots=\(snapshots.count)")
            return snapshots
        }

        var enrichedSnapshots = snapshots

        for processIdentifier in Set(snapshots.map({ $0.identity.ownerProcessIdentifier })) {
            guard let axSnapshots = axSnapshotsByPID[processIdentifier], !axSnapshots.isEmpty else { continue }
            BokslTabDiagnosticLog.write(
                "window-catalog.ax pid=\(processIdentifier) cgCount=\(snapshots.filter { $0.identity.ownerProcessIdentifier == processIdentifier }.count) axCount=\(axSnapshots.count)"
            )
            axSnapshots.enumerated().forEach { index, snapshot in
                BokslTabDiagnosticLog.write("window-catalog.ax.candidate pid=\(processIdentifier) index=\(index) \(snapshot.diagnosticDescription)")
            }

            let snapshotIndices = enrichedSnapshots.indices.filter {
                enrichedSnapshots[$0].identity.ownerProcessIdentifier == processIdentifier
            }
            var usedAXIndices = Set<Int>()

            for snapshotIndex in snapshotIndices {
                let availableAXIndices = axSnapshots.indices.filter { !usedAXIndices.contains($0) }
                guard let axIndex = bestAccessibilityMatchIndex(
                    for: enrichedSnapshots[snapshotIndex],
                    candidates: axSnapshots,
                    candidateIndices: availableAXIndices
                ) else { continue }

                usedAXIndices.insert(axIndex)
                enrichedSnapshots[snapshotIndex] = enrichedSnapshots[snapshotIndex].withTitle(
                    WindowTitleSelectionPolicy.bestTitle(
                        coreGraphicsTitle: enrichedSnapshots[snapshotIndex].identity.title,
                        accessibilityTitle: axSnapshots[axIndex].title,
                        ownerName: enrichedSnapshots[snapshotIndex].ownerName
                    )
                )
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.match cgWindow=\(enrichedSnapshots[snapshotIndex].identity.windowID) pid=\(processIdentifier) axIndex=\(axIndex) title=\(enrichedSnapshots[snapshotIndex].identity.title.catalogDiagnosticValue)"
                )
            }

            let weakTitleSnapshotIndices = snapshotIndices.filter {
                WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(enrichedSnapshots[$0])
            }
            let availableTitles = axSnapshots.indices
                .filter { !usedAXIndices.contains($0) }
                .compactMap { axSnapshots[$0].title }
            let fallbackAssignments = AXTitleFallbackPolicy.assignUniqueTitles(
                candidateWindowIDs: weakTitleSnapshotIndices.map { enrichedSnapshots[$0].identity.windowID },
                availableTitles: availableTitles
            )

            for snapshotIndex in weakTitleSnapshotIndices {
                let windowID = enrichedSnapshots[snapshotIndex].identity.windowID
                if let title = fallbackAssignments[windowID] {
                    enrichedSnapshots[snapshotIndex] = enrichedSnapshots[snapshotIndex].withTitle(title)
                    BokslTabDiagnosticLog.write(
                        "window-catalog.ax.titleFallback cgWindow=\(windowID) pid=\(processIdentifier) title=\(title.catalogDiagnosticValue)"
                    )
                }
            }

            let weakTitleWindowIDs = snapshotIndices
                .filter { WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(enrichedSnapshots[$0]) }
                .map { enrichedSnapshots[$0].identity.windowID }
            if !weakTitleWindowIDs.isEmpty {
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.unmatched pid=\(processIdentifier) weakTitleWindows=\(weakTitleWindowIDs.map(String.init).joined(separator: ",")) usedAX=\(usedAXIndices.count)/\(axSnapshots.count)"
                )
            }
        }

        return enrichedSnapshots
    }

    private func filterLikelyDuplicateUntitledSnapshots(_ snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        let filtered = WindowCatalogDuplicateFilterPolicy.filter(snapshots)
        let includedIDs = Set(filtered.map(\.diagnosticID))
        let excluded = snapshots.filter { !includedIDs.contains($0.diagnosticID) }
        excluded.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.exclude reason=untitled-duplicate-of-titled-window \(snapshot.diagnosticDescription)")
        }
        return filtered
    }

    private func accessibilityOnlySnapshotsForAppsWithoutCGWindows(
        _ apps: [AppIdentity],
        includedSnapshots: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        guard !apps.isEmpty else { return [] }
        guard AXIsProcessTrusted() else {
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-only skipped reason=accessibility-untrusted apps=\(apps.count)"
            )
            return []
        }

        let representedPIDs = Set(includedSnapshots.map { $0.identity.ownerProcessIdentifier })
        let missingApps = apps.filter { !representedPIDs.contains($0.processIdentifier) }
        guard !missingApps.isEmpty else {
            BokslTabDiagnosticLog.write("window-catalog.ax-only skipped reason=no-missing-apps apps=\(apps.count)")
            return []
        }

        let axSnapshotsByPID = accessibilityWindowSnapshotsByPID(
            Set(missingApps.map(\.processIdentifier))
        )
        let axOnlySnapshots = AXOnlyWindowCatalogPolicy.snapshotsForAppsWithoutCGWindows(
            apps: missingApps,
            axSnapshotsByPID: axSnapshotsByPID
        )
        let includedByPID = Dictionary(grouping: axOnlySnapshots, by: { $0.identity.ownerProcessIdentifier })
        BokslTabDiagnosticLog.write(
            "window-catalog.ax-only missingApps=\(missingApps.count) fetchedPIDs=\(axSnapshotsByPID.count) included=\(axOnlySnapshots.count)"
        )
        missingApps.forEach { app in
            let axCount = axSnapshotsByPID[app.processIdentifier]?.count ?? 0
            let includedCount = includedByPID[app.processIdentifier]?.count ?? 0
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-only.app pid=\(app.processIdentifier) name=\(app.displayName.catalogDiagnosticValue) axSnapshots=\(axCount) included=\(includedCount)"
            )
        }
        axOnlySnapshots.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.ax-only.include \(snapshot.diagnosticDescription)")
        }
        return axOnlySnapshots
    }

    private func cachedTitleSnapshotsForAppsWithoutWindows(
        _ apps: [AppIdentity],
        includedSnapshots: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        guard !apps.isEmpty else { return [] }

        let representedPIDs = Set(includedSnapshots.map { $0.identity.ownerProcessIdentifier })
        let missingApps = apps.filter { !representedPIDs.contains($0.processIdentifier) }
        guard !missingApps.isEmpty else {
            BokslTabDiagnosticLog.write("window-catalog.cache skipped reason=no-missing-apps apps=\(apps.count)")
            return []
        }

        let snapshots = titleCache.snapshots(for: missingApps, excluding: representedPIDs)
        let includedByPID = Dictionary(grouping: snapshots, by: { $0.identity.ownerProcessIdentifier })
        BokslTabDiagnosticLog.write(
            "window-catalog.cache missingApps=\(missingApps.count) included=\(snapshots.count)"
        )
        missingApps.forEach { app in
            let includedCount = includedByPID[app.processIdentifier]?.count ?? 0
            if includedCount == 0 {
                BokslTabDiagnosticLog.write(
                    "window-catalog.cache.miss pid=\(app.processIdentifier) name=\(app.displayName.catalogDiagnosticValue)"
                )
            }
        }
        snapshots.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.cache.include \(snapshot.diagnosticDescription)")
        }
        return snapshots
    }

    private func accessibilityWindowSnapshotsByPID(_ processIdentifiers: Set<Int32>) -> [Int32: [AccessibilityWindowSnapshot]] {
        var snapshotsByPID: [Int32: [AccessibilityWindowSnapshot]] = [:]

        for processIdentifier in processIdentifiers {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            var rawWindows: CFTypeRef?
            let windowsError = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &rawWindows
            )
            let axWindows = windowsError == .success
                ? (rawWindows as? [AXUIElement] ?? [])
                : []
            let supplementalWindows = axWindows.isEmpty
                ? supplementalAccessibilityWindows(
                    from: appElement,
                    processIdentifier: processIdentifier
                )
                : []

            let snapshots = AccessibilityWindowSnapshot.deduplicated(
                (axWindows + supplementalWindows).compactMap(AccessibilityWindowSnapshot.init(window:))
            )
            if !snapshots.isEmpty {
                snapshotsByPID[processIdentifier] = snapshots
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.fetch pid=\(processIdentifier) raw=\(axWindows.count) supplemental=\(supplementalWindows.count) snapshots=\(snapshots.count)"
                )
            } else {
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.fetch pid=\(processIdentifier) raw=\(axWindows.count) supplemental=\(supplementalWindows.count) snapshots=0 error=\(windowsError.rawValue)"
                )
            }
        }

        return snapshotsByPID
    }

    private func supplementalAccessibilityWindows(
        from appElement: AXUIElement,
        processIdentifier: Int32
    ) -> [AXUIElement] {
        [
            ("main", kAXMainWindowAttribute),
            ("focused", kAXFocusedWindowAttribute)
        ].compactMap { label, attribute in
            var rawWindow: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &rawWindow)
            guard error == .success,
                  let rawWindow,
                  CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
            else {
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.supplemental pid=\(processIdentifier) attr=\(label) result=missing error=\(error.rawValue)"
                )
                return nil
            }
            BokslTabDiagnosticLog.write(
                "window-catalog.ax.supplemental pid=\(processIdentifier) attr=\(label) result=window"
            )
            let window = rawWindow as! AXUIElement
            return window
        }
    }

    private func bestAccessibilityMatchIndex(
        for snapshot: WindowSnapshot,
        candidates: [AccessibilityWindowSnapshot],
        candidateIndices: [Int]
    ) -> Int? {
        AccessibilityWindowMatchPolicy.bestMatchIndex(
            for: snapshot,
            candidates: candidates,
            candidateIndices: candidateIndices
        )
    }
}

struct AccessibilityWindowMatchPolicy {
    static func bestMatchIndex(
        for snapshot: WindowSnapshot,
        candidates: [AccessibilityWindowSnapshot],
        candidateIndices: [Int]
    ) -> Int? {
        let candidateFrames = candidateIndices.map { candidates[$0].frame }

        if let localIndex = WindowFrameMatchPolicy.bestFrameMatchIndex(
            targetFrame: snapshot.bounds,
            candidateFrames: candidateFrames
        ) {
            return candidateIndices[localIndex]
        }

        if let localIndex = WindowFrameMatchPolicy.bestSizeMatchIndex(
            targetFrame: snapshot.bounds,
            candidateFrames: candidateFrames
        ) {
            return candidateIndices[localIndex]
        }

        return nil
    }
}

struct WindowFrameMatchPolicy {
    static let maximumFrameDistance: CGFloat = 24
    static let maximumSizeDistance: CGFloat = 12

    static func bestFrameMatchIndex(targetFrame: CGRect, candidateFrames: [CGRect]) -> Int? {
        bestUniqueMatchIndex(
            distances: candidateFrames.map { $0.frameDistance(to: targetFrame) },
            maximumDistance: maximumFrameDistance
        )
    }

    static func bestSizeMatchIndex(targetFrame: CGRect, candidateFrames: [CGRect]) -> Int? {
        bestUniqueMatchIndex(
            distances: candidateFrames.map { $0.sizeDistance(to: targetFrame) },
            maximumDistance: maximumSizeDistance
        )
    }

    private static func bestUniqueMatchIndex(distances: [CGFloat], maximumDistance: CGFloat) -> Int? {
        let matches = distances.enumerated()
            .map { index, distance in (index: index, distance: distance) }
            .filter { $0.distance <= maximumDistance }
            .sorted { lhs, rhs in lhs.distance < rhs.distance }

        guard let best = matches.first else { return nil }
        if matches.dropFirst().contains(where: { $0.distance == best.distance }) {
            return nil
        }
        return best.index
    }
}

struct AXTitleFallbackPolicy {
    static func assignUniqueTitles(candidateWindowIDs: [UInt32], availableTitles: [String]) -> [UInt32: String] {
        let normalizedTitles = availableTitles.compactMap(\.nonBlankCatalogTitle)
        guard !candidateWindowIDs.isEmpty,
              candidateWindowIDs.count == normalizedTitles.count,
              Set(normalizedTitles).count == normalizedTitles.count
        else { return [:] }

        let sortedWindowIDs = candidateWindowIDs.sorted()
        let sortedTitles = normalizedTitles.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: zip(sortedWindowIDs, sortedTitles))
    }
}

struct WindowTitleFallbackCandidatePolicy {
    static func needsAccessibilityFallback(_ snapshot: WindowSnapshot) -> Bool {
        snapshot.identity.title?.nonBlankCatalogTitle == nil
            || WindowTitleSelectionPolicy.isGenericTitle(
                coreGraphicsTitle: snapshot.identity.title,
                ownerName: snapshot.ownerName
            )
    }
}

struct WindowCatalogDuplicateFilterPolicy {
    static let minimumDuplicateOverlapRatio: CGFloat = 0.92
    static let maximumDuplicateFrameDistance: CGFloat = 48
    static let maximumThinAuxiliaryHeight: CGFloat = 120
    static let minimumAuxiliaryWidthOverlapRatio: CGFloat = 0.80
    static let maximumAuxiliaryEdgeGap: CGFloat = 4

    static func filter(_ snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        let titledBoundsByPID = Dictionary(grouping: snapshots, by: { $0.identity.ownerProcessIdentifier })
            .mapValues { processSnapshots in
                processSnapshots
                    .filter { $0.identity.title?.nonBlankCatalogTitle != nil }
                    .map(\.bounds)
            }

        return snapshots.filter { snapshot in
            guard snapshot.identity.title?.nonBlankCatalogTitle == nil else { return true }
            let titledBounds = titledBoundsByPID[snapshot.identity.ownerProcessIdentifier] ?? []
            return !shouldSuppressUntitledWindow(bounds: snapshot.bounds, sameProcessTitledBounds: titledBounds)
        }
    }

    static func shouldSuppressUntitledWindow(bounds: CGRect, sameProcessTitledBounds: [CGRect]) -> Bool {
        sameProcessTitledBounds.contains { titledBounds in
            isLikelyDuplicateGeometry(bounds, titledBounds)
                || isLikelyThinAuxiliaryWindow(bounds, attachedTo: titledBounds)
        }
    }

    static func isLikelyDuplicateGeometry(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.frameDistance(to: rhs) <= maximumDuplicateFrameDistance
            || lhs.overlapRatio(with: rhs) >= minimumDuplicateOverlapRatio
    }

    static func isLikelyThinAuxiliaryWindow(_ bounds: CGRect, attachedTo titledBounds: CGRect) -> Bool {
        guard bounds.height > 0, bounds.height <= maximumThinAuxiliaryHeight else { return false }
        guard bounds.horizontalOverlapRatio(with: titledBounds) >= minimumAuxiliaryWidthOverlapRatio else {
            return false
        }

        let touchesTopEdge = abs(bounds.maxY - titledBounds.minY) <= maximumAuxiliaryEdgeGap
            || abs(bounds.minY - titledBounds.minY) <= maximumAuxiliaryEdgeGap
        let touchesBottomEdge = abs(bounds.minY - titledBounds.maxY) <= maximumAuxiliaryEdgeGap
            || abs(bounds.maxY - titledBounds.maxY) <= maximumAuxiliaryEdgeGap
        return touchesTopEdge || touchesBottomEdge
    }
}

struct AXOnlyWindowCatalogPolicy {
    static func snapshotsForAppsWithoutCGWindows(
        apps: [AppIdentity],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]]
    ) -> [WindowSnapshot] {
        apps.flatMap { app in
            (axSnapshotsByPID[app.processIdentifier] ?? []).enumerated().compactMap { index, axSnapshot in
                guard let title = axSnapshot.title?.nonBlankCatalogTitle,
                      WindowSnapshot.isReasonableWindowBounds(axSnapshot.frame)
                else { return nil }

                return WindowSnapshot(
                    identity: WindowIdentity(
                        windowID: SyntheticWindowID.axOnly(
                            processIdentifier: app.processIdentifier,
                            title: title,
                            frame: axSnapshot.frame,
                            index: index
                        ),
                        ownerProcessIdentifier: app.processIdentifier,
                        title: title
                    ),
                    bounds: axSnapshot.frame,
                    ownerName: app.displayName
                )
            }
        }
    }
}

final class WindowTitleCache {
    struct Entry {
        let ownerProcessIdentifier: Int32
        let ownerName: String?
        let title: String
        let bounds: CGRect
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
                ownerProcessIdentifier: processIdentifier,
                ownerName: snapshot.ownerName,
                title: title,
                bounds: snapshot.bounds
            )
            touch(processIdentifier)
            recordedPIDs.insert(processIdentifier)
            BokslTabDiagnosticLog.write(
                "window-catalog.cache.record pid=\(processIdentifier) sourceWindow=\(snapshot.identity.windowID) title=\(title.catalogDiagnosticValue) bounds=\(snapshot.bounds.catalogDiagnosticDescription)"
            )
        }
    }

    func snapshots(for apps: [AppIdentity], excluding representedPIDs: Set<Int32>) -> [WindowSnapshot] {
        apps.enumerated().compactMap { index, app in
            guard !representedPIDs.contains(app.processIdentifier),
                  let entry = cachedEntry(
                      processIdentifier: app.processIdentifier,
                      appDisplayName: app.displayName
                  )
            else { return nil }

            return WindowSnapshot(
                identity: WindowIdentity(
                    windowID: SyntheticWindowID.cached(
                        processIdentifier: entry.ownerProcessIdentifier,
                        title: entry.title,
                        frame: entry.bounds,
                        index: index
                    ),
                    ownerProcessIdentifier: entry.ownerProcessIdentifier,
                    title: entry.title
                ),
                bounds: entry.bounds,
                ownerName: entry.ownerName ?? app.displayName
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
            BokslTabDiagnosticLog.write(
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
            BokslTabDiagnosticLog.write("window-catalog.cache.evict pid=\(evictedPID) reason=max-entries-\(maxEntries)")
        }
    }
}

enum SyntheticWindowID {
    static func axOnly(
        processIdentifier: Int32,
        title: String,
        frame: CGRect,
        index: Int
    ) -> UInt32 {
        0x8000_0000 | (hash(
            processIdentifier: processIdentifier,
            title: title,
            frame: frame,
            index: index
        ) & 0x7fff_ffff)
    }

    static func cached(
        processIdentifier: Int32,
        title: String,
        frame: CGRect,
        index: Int
    ) -> UInt32 {
        0x4000_0000 | (hash(
            processIdentifier: processIdentifier,
            title: title,
            frame: frame,
            index: index
        ) & 0x3fff_ffff)
    }

    private static func hash(
        processIdentifier: Int32,
        title: String,
        frame: CGRect,
        index: Int
    ) -> UInt32 {
        let key = [
            "\(processIdentifier)",
            "\(index)",
            "\(Int(frame.origin.x))",
            "\(Int(frame.origin.y))",
            "\(Int(frame.size.width))",
            "\(Int(frame.size.height))",
            title
        ].joined(separator: "|")
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

struct WindowTitleSelectionPolicy {
    static func bestTitle(
        coreGraphicsTitle: String?,
        accessibilityTitle: String?,
        ownerName: String? = nil
    ) -> String? {
        guard let axTitle = accessibilityTitle?.nonBlankCatalogTitle else {
            return coreGraphicsTitle?.nonBlankCatalogTitle
        }
        guard let cgTitle = coreGraphicsTitle?.nonBlankCatalogTitle else {
            return axTitle
        }
        guard axTitle != cgTitle else { return cgTitle }

        if isGenericTitle(coreGraphicsTitle: cgTitle, ownerName: ownerName) {
            return axTitle
        }

        // AX titles often include document/page context while CG can be truncated or generic.
        return axTitle.count > cgTitle.count ? axTitle : cgTitle
    }

    static func isGenericTitle(coreGraphicsTitle: String?, ownerName: String?) -> Bool {
        guard let title = coreGraphicsTitle?.nonBlankCatalogTitle,
              let ownerName = ownerName?.nonBlankCatalogTitle
        else { return false }
        return title.localizedCaseInsensitiveCompare(ownerName) == .orderedSame
    }
}

struct WindowSnapshot {
    let identity: WindowIdentity
    let bounds: CGRect
    let ownerName: String?

    init(identity: WindowIdentity, bounds: CGRect, ownerName: String? = nil) {
        self.identity = identity
        self.bounds = bounds
        self.ownerName = ownerName?.nonBlankCatalogTitle
    }

    static func parse(windowInfo: [String: Any]) -> WindowSnapshotParseResult {
        let layerNumber = windowInfo[kCGWindowLayer as String] as? NSNumber
        let pidNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber
        let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber
        let bounds = CGRect.fromWindowInfo(windowInfo[kCGWindowBounds as String])
        let title = (windowInfo[kCGWindowName as String] as? String)?.nonBlankCatalogTitle
        let ownerName = (windowInfo[kCGWindowOwnerName as String] as? String)?.nonBlankCatalogTitle

        guard let layerNumber else {
            return .rejected(reason: "missing-layer")
        }
        guard layerNumber.intValue == 0 else {
            return .rejected(reason: "nonzero-layer-\(layerNumber.intValue)")
        }
        guard let pidNumber else {
            return .rejected(reason: "missing-pid")
        }
        guard let windowNumber else {
            return .rejected(reason: "missing-window-number")
        }
        guard let bounds else {
            return .rejected(reason: "missing-bounds")
        }
        guard WindowSnapshot.isReasonableWindowBounds(bounds) else {
            return .rejected(reason: "small-bounds")
        }

        return .accepted(
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: windowNumber.uint32Value,
                    ownerProcessIdentifier: pidNumber.int32Value,
                    title: title
                ),
                bounds: bounds,
                ownerName: ownerName
            )
        )
    }

    func withTitle(_ title: String?) -> WindowSnapshot {
        WindowSnapshot(
            identity: WindowIdentity(
                windowID: identity.windowID,
                ownerProcessIdentifier: identity.ownerProcessIdentifier,
                title: title
            ),
            bounds: bounds,
            ownerName: ownerName
        )
    }

    static func isReasonableWindowBounds(_ bounds: CGRect) -> Bool {
        bounds.width >= 40 && bounds.height >= 40
    }

    var diagnosticDescription: String {
        "window=\(identity.windowID) pid=\(identity.ownerProcessIdentifier) owner=\(ownerName.catalogDiagnosticValue) title=\(identity.title.catalogDiagnosticValue) bounds=\(bounds.catalogDiagnosticDescription)"
    }

    var diagnosticID: String {
        "\(identity.ownerProcessIdentifier):\(identity.windowID)"
    }
}

enum WindowSnapshotParseResult {
    case accepted(WindowSnapshot)
    case rejected(reason: String)

    var snapshot: WindowSnapshot? {
        if case .accepted(let snapshot) = self { return snapshot }
        return nil
    }

    var rejectionReason: String? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }

    static func rejectionSummary(_ results: [WindowSnapshotParseResult]) -> String {
        let counts = Dictionary(grouping: results.compactMap(\.rejectionReason), by: { $0 })
            .mapValues(\.count)
        guard !counts.isEmpty else { return "none" }
        return counts
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }
}

struct AccessibilityWindowSnapshot {
    let title: String?
    let frame: CGRect

    init(title: String?, frame: CGRect) {
        self.title = title?.nonBlankCatalogTitle
        self.frame = frame
    }

    static func deduplicated(_ snapshots: [AccessibilityWindowSnapshot]) -> [AccessibilityWindowSnapshot] {
        var seenKeys = Set<String>()
        return snapshots.filter { snapshot in
            let key = [
                snapshot.title?.nonBlankCatalogTitle ?? "",
                snapshot.frame.catalogDiagnosticDescription
            ].joined(separator: "|")
            return seenKeys.insert(key).inserted
        }
    }

    init?(window: AXUIElement) {
        guard let frame = CGRect.fromAccessibilityWindow(window) else { return nil }
        self.title = AccessibilityWindowSnapshot.title(of: window)
        self.frame = frame
    }

    private static func title(of window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else {
            return nil
        }
        return (rawTitle as? String)?.nonBlankCatalogTitle
    }

    var diagnosticDescription: String {
        "title=\(title.catalogDiagnosticValue) frame=\(frame.catalogDiagnosticDescription)"
    }
}

private extension CGRect {
    static func fromWindowInfo(_ rawBounds: Any?) -> CGRect? {
        guard let dictionary = rawBounds as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    static func fromAccessibilityWindow(_ window: AXUIElement) -> CGRect? {
        guard let origin = CGPoint.fromAccessibilityValue(window, attribute: kAXPositionAttribute),
              let size = CGSize.fromAccessibilityValue(window, attribute: kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func frameDistance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX)
            + abs(minY - other.minY)
            + abs(width - other.width)
            + abs(height - other.height)
    }

    func sizeDistance(to other: CGRect) -> CGFloat {
        abs(width - other.width) + abs(height - other.height)
    }

    func overlapRatio(with other: CGRect) -> CGFloat {
        let intersection = intersection(other)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let denominator = min(area, other.area)
        guard denominator > 0 else { return 0 }
        return intersection.area / denominator
    }

    func horizontalOverlapRatio(with other: CGRect) -> CGFloat {
        let overlap = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let denominator = min(width, other.width)
        guard denominator > 0 else { return 0 }
        return overlap / denominator
    }

    var area: CGFloat {
        max(0, width) * max(0, height)
    }

    var catalogDiagnosticDescription: String {
        "x=\(Int(origin.x)),y=\(Int(origin.y)),w=\(Int(size.width)),h=\(Int(size.height))"
    }
}

private extension CGPoint {
    static func fromAccessibilityValue(_ window: AXUIElement, attribute: String) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &rawValue) == .success,
              let value = rawValue,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }

        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }
}

private extension CGSize {
    static func fromAccessibilityValue(_ window: AXUIElement, attribute: String) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &rawValue) == .success,
              let value = rawValue,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize
        else { return nil }

        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

private extension String {
    var nonBlankCatalogTitle: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var catalogDiagnosticValue: String {
        let singleLine = replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if singleLine.count <= 120 { return "\"\(singleLine)\"" }
        return "\"\(singleLine.prefix(117))...\""
    }
}

private extension Optional where Wrapped == String {
    var catalogDiagnosticValue: String {
        guard let self, let nonBlank = self.nonBlankCatalogTitle else { return "nil" }
        return nonBlank.catalogDiagnosticValue
    }
}
