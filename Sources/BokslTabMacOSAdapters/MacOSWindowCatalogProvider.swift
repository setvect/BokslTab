import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSWindowCatalogProvider: WindowCatalogProviding, WindowCatalogRefreshing {
    private var titleCache = WindowTitleCache()
    private let accessibility: MacOSAccessibilityService
    private let windowInfoList: () -> [[String: Any]]?
    private let isAccessibilityTrusted: () -> Bool
    private let accessibilitySnapshotLoader: ((Int32, Bool) -> [AccessibilityWindowSnapshot]?)?
    private let accessibilityEventCache: AccessibilityWindowEventCache
    private let accessibilityCache: BackgroundRefreshCache<Int32, [AccessibilityWindowSnapshot]>

    public var onDidRefresh: (() -> Void)? {
        get { accessibilityCache.onRefresh }
        set { accessibilityCache.onRefresh = newValue }
    }

    public convenience init(accessibility: MacOSAccessibilityService = MacOSAccessibilityService()) {
        self.init(accessibility: accessibility, windowInfoList: {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        })
    }

    init(
        accessibility: MacOSAccessibilityService,
        windowInfoList: @escaping () -> [[String: Any]]? = {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        },
        isAccessibilityTrusted: @escaping () -> Bool = AXIsProcessTrusted,
        accessibilitySnapshotLoader: ((Int32, Bool) -> [AccessibilityWindowSnapshot]?)? = nil
    ) {
        self.accessibility = accessibility
        self.windowInfoList = windowInfoList
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.accessibilitySnapshotLoader = accessibilitySnapshotLoader
        self.accessibilityEventCache = accessibility.eventCache
        self.accessibilityCache = BackgroundRefreshCache(queue: accessibility.workerQueue)
    }

    public func windowsForAllApps() -> [WindowIdentity] {
        currentOnScreenWindows(augmentingWithAccessibilityFor: [])
    }

    public func windowsForAllApps(including apps: [AppIdentity]) -> [WindowIdentity] {
        currentOnScreenWindows(augmentingWithAccessibilityFor: apps)
    }

    public func windows(for app: AppIdentity) -> [WindowIdentity] {
        currentOnScreenWindows(augmentingWithAccessibilityFor: [app])
            .filter { $0.ownerProcessIdentifier == app.processIdentifier }
    }

    public func requestRefresh(including apps: [AppIdentity]) {
        let snapshots = (windowInfoList() ?? []).compactMap { WindowSnapshot.parse(windowInfo: $0).snapshot }
        let tabExpansionEligibilityByPID = tabExpansionEligibilityByPID(for: snapshots, apps: apps)
        let tabResolutionEligiblePIDs = Set(
            tabExpansionEligibilityByPID.compactMap { processIdentifier, decision in
                decision.canExpandTabs ? processIdentifier : nil
            }
        )
        let accessibilityTrusted = isAccessibilityTrusted()
        if !accessibilityTrusted { titleCache = WindowTitleCache() }
        let requestedPIDs = Set(snapshots.map { $0.identity.ownerProcessIdentifier })
            .union(apps.map(\.processIdentifier))
        accessibilityCache.retainOnly(accessibilityTrusted ? requestedPIDs : [])
        accessibility.retainOnly(requestedPIDs)
        if accessibilityTrusted {
            let descriptors = accessibilityEventObserverDescriptors(
                snapshots: snapshots,
                apps: apps,
                eligibilityByPID: tabExpansionEligibilityByPID
            )
            accessibilityEventCache.scheduleObserverPruning(to: Set(descriptors.map(\.processIdentifier)))
            let descriptorsByPID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.processIdentifier, $0) })
            for pid in requestedPIDs.sorted() {
                accessibilityCache.refresh(pid) { [weak self] in
                    guard let self else { return nil }
                    return self.accessibility.perform(for: pid) { query in
                        if let load = self.accessibilitySnapshotLoader {
                            let value = load(pid, tabResolutionEligiblePIDs.contains(pid))
                            if value == nil { query.record(.cannotComplete) }
                            return value
                        }
                        let snapshots = AccessibilityWindowDiscovery.snapshots(
                            for: pid, resolveTabs: tabResolutionEligiblePIDs.contains(pid), query: query
                        )
                        if let descriptor = descriptorsByPID[pid] {
                            self.accessibilityEventCache.ensureObserver(for: descriptor, query: query)
                            self.accessibilityEventCache.seedCurrentWindows(for: [pid], query: query)
                        }
                        return snapshots
                    }
                }
            }
        } else {
            accessibilityEventCache.scheduleObserverPruning(to: [])
        }
    }

    private func currentOnScreenWindows(augmentingWithAccessibilityFor apps: [AppIdentity]) -> [WindowIdentity] {
        guard let infoList = windowInfoList() else {
            BokslTabDiagnosticLog.debug("window-catalog.cg unavailable")
            return []
        }

        let parseResults = infoList.map(WindowSnapshot.parse(windowInfo:))
        let snapshots = parseResults.compactMap(\.snapshot)
        let rejectionSummary = WindowSnapshotParseResult.rejectionSummary(parseResults)
        BokslTabDiagnosticLog.debug(
            "window-catalog.cg raw=\(infoList.count) candidates=\(snapshots.count) rejected=\(rejectionSummary)"
        )
        snapshots.forEach { snapshot in
            BokslTabDiagnosticLog.debug("window-catalog.cg.candidate \(snapshot.diagnosticDescription)")
        }

        let tabExpansionEligibilityByPID = tabExpansionEligibilityByPID(for: snapshots, apps: apps)
        let accessibilityTrusted = isAccessibilityTrusted()
        if !accessibilityTrusted {
            titleCache = WindowTitleCache()
            accessibilityCache.retainOnly([])
        }
        let requestedPIDs = Set(snapshots.map { $0.identity.ownerProcessIdentifier })
            .union(apps.map(\.processIdentifier))
        let axSnapshotsByPID = Dictionary(uniqueKeysWithValues: requestedPIDs.compactMap { pid in
            accessibilityCache.value(for: pid).map { (pid, $0) }
        })
        let enrichedSnapshots = enrichTitlesFromAccessibilityIfPossible(
            snapshots,
            axSnapshotsByPID: axSnapshotsByPID
        )
        let cachedEnrichedSnapshots = titleCache.applyCachedTitles(to: enrichedSnapshots)
        let filteredSnapshots = filterLikelyDuplicateUntitledSnapshots(cachedEnrichedSnapshots)
        let tabExpandedSnapshots = expandWindowTabsIfPossible(
            filteredSnapshots,
            axSnapshotsByPID: axSnapshotsByPID,
            tabExpansionEligibilityByPID: tabExpansionEligibilityByPID
        )
        let axOnlySnapshots = accessibilityOnlySnapshotsForAppsWithoutCGWindows(
            apps,
            includedSnapshots: tabExpandedSnapshots,
            axSnapshotsByPID: axSnapshotsByPID
        )
        let accessibilityEventSnapshots = accessibilityEventCachedSnapshotsForEligibleApps(
            includedSnapshots: tabExpandedSnapshots + axOnlySnapshots,
            eligiblePIDs: accessibilityTrusted ? Set(tabExpansionEligibilityByPID.compactMap { $0.value.canExpandTabs ? $0.key : nil }) : []
        )
        let liveSnapshots = tabExpandedSnapshots + axOnlySnapshots + accessibilityEventSnapshots
        titleCache.record(filteredSnapshots + axOnlySnapshots)
        let resultSnapshots = liveSnapshots
        BokslTabDiagnosticLog.debug(
            "window-catalog.result candidates=\(snapshots.count) enriched=\(enrichedSnapshots.count) cgIncluded=\(filteredSnapshots.count) tabExpanded=\(tabExpandedSnapshots.count) axOnly=\(axOnlySnapshots.count) axEventCached=\(accessibilityEventSnapshots.count) cached=0 included=\(resultSnapshots.count)"
        )
        resultSnapshots.forEach { snapshot in
            BokslTabDiagnosticLog.debug("window-catalog.include \(snapshot.diagnosticDescription)")
        }
        return resultSnapshots.map(\.identity)
    }

    private func enrichTitlesFromAccessibilityIfPossible(
        _ snapshots: [WindowSnapshot],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]]
    ) -> [WindowSnapshot] {
        guard isAccessibilityTrusted() else {
            BokslTabDiagnosticLog.debug("window-catalog.ax skipped reason=accessibility-untrusted snapshots=\(snapshots.count)")
            return snapshots
        }

        guard !axSnapshotsByPID.isEmpty else {
            BokslTabDiagnosticLog.debug("window-catalog.ax empty snapshots=\(snapshots.count)")
            return snapshots
        }

        var enrichedSnapshots = snapshots

        for processIdentifier in Set(snapshots.map({ $0.identity.ownerProcessIdentifier })) {
            guard let axSnapshots = axSnapshotsByPID[processIdentifier], !axSnapshots.isEmpty else { continue }
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax pid=\(processIdentifier) cgCount=\(snapshots.filter { $0.identity.ownerProcessIdentifier == processIdentifier }.count) axCount=\(axSnapshots.count)"
            )
            axSnapshots.enumerated().forEach { index, snapshot in
                BokslTabDiagnosticLog.debug("window-catalog.ax.candidate pid=\(processIdentifier) index=\(index) \(snapshot.diagnosticDescription)")
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
                BokslTabDiagnosticLog.debug(
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
                    BokslTabDiagnosticLog.debug(
                        "window-catalog.ax.titleFallback cgWindow=\(windowID) pid=\(processIdentifier) title=\(title.catalogDiagnosticValue)"
                    )
                }
            }

            let weakTitleWindowIDs = snapshotIndices
                .filter { WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(enrichedSnapshots[$0]) }
                .map { enrichedSnapshots[$0].identity.windowID }
            if !weakTitleWindowIDs.isEmpty {
                BokslTabDiagnosticLog.debug(
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
            BokslTabDiagnosticLog.debug("window-catalog.exclude reason=untitled-duplicate-of-titled-window \(snapshot.diagnosticDescription)")
        }
        return filtered
    }

    private func expandWindowTabsIfPossible(
        _ snapshots: [WindowSnapshot],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]],
        tabExpansionEligibilityByPID: [Int32: AppTabExpansionEligibilityDecision]
    ) -> [WindowSnapshot] {
        guard isAccessibilityTrusted() else {
            BokslTabDiagnosticLog.debug("window-catalog.ax.tabs.skip reason=accessibility-untrusted snapshots=\(snapshots.count)")
            return snapshots
        }

        guard !axSnapshotsByPID.isEmpty else {
            BokslTabDiagnosticLog.debug("window-catalog.ax.tabs.skip reason=no-ax-snapshots snapshots=\(snapshots.count)")
            return snapshots
        }

        return snapshots.flatMap { snapshot -> [WindowSnapshot] in
            let eligibility = tabExpansionEligibilityByPID[snapshot.identity.ownerProcessIdentifier]
            guard eligibility?.canExpandTabs == true else {
                BokslTabDiagnosticLog.debug(
                    "window-catalog.ax.tabs.skip reason=\(eligibility?.skipReason ?? "unsupported-app-for-window-tabs") pid=\(snapshot.identity.ownerProcessIdentifier) window=\(snapshot.identity.windowID) owner=\(snapshot.ownerName.catalogDiagnosticValue)"
                )
                return [snapshot]
            }

            guard let axSnapshots = axSnapshotsByPID[snapshot.identity.ownerProcessIdentifier],
                  let axIndex = bestAccessibilityMatchIndex(
                      for: snapshot,
                      candidates: axSnapshots,
                      candidateIndices: Array(axSnapshots.indices)
                  )
            else {
                BokslTabDiagnosticLog.debug(
                    "window-catalog.ax.tabs.skip reason=parent-ax-match-missing pid=\(snapshot.identity.ownerProcessIdentifier) window=\(snapshot.identity.windowID)"
                )
                return [snapshot]
            }

            let axSnapshot = axSnapshots[axIndex]
            let result = TabExpandedWindowCatalogPolicy.expand(
                snapshot: snapshot,
                tabs: axSnapshot.tabs,
                parentFrame: axSnapshot.frame.windowFrameIdentity
            )
            if result.didExpand {
                let selected = axSnapshot.tabs.first(where: \.isSelected)?.index
                let titledCount = axSnapshot.tabs.filter { $0.title?.nonBlankCatalogTitle != nil }.count
                BokslTabDiagnosticLog.debug(
                    "window-catalog.ax.tabs app=\(snapshot.ownerName.catalogDiagnosticValue) pid=\(snapshot.identity.ownerProcessIdentifier) window=\(snapshot.identity.windowID) source=\(axSnapshot.tabSource?.rawValue ?? "unknown") count=\(axSnapshot.tabs.count) titled=\(titledCount) selected=\(selected.map(String.init) ?? "nil") durationMs=\(axSnapshot.tabDurationMs)"
                )
            } else {
                BokslTabDiagnosticLog.debug(
                    "window-catalog.ax.tabs.skip reason=\(result.fallbackReason ?? axSnapshot.tabSkipReason ?? "no-tabs") pid=\(snapshot.identity.ownerProcessIdentifier) window=\(snapshot.identity.windowID) source=\(axSnapshot.tabSource?.rawValue ?? "missing") durationMs=\(axSnapshot.tabDurationMs)"
                )
            }
            return result.snapshots
        }
    }

    private func accessibilityOnlySnapshotsForAppsWithoutCGWindows(
        _ apps: [AppIdentity],
        includedSnapshots: [WindowSnapshot],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]]
    ) -> [WindowSnapshot] {
        guard !apps.isEmpty else { return [] }
        guard isAccessibilityTrusted() else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-only skipped reason=accessibility-untrusted apps=\(apps.count)"
            )
            return []
        }

        let representedPIDs = Set(includedSnapshots.map { $0.identity.ownerProcessIdentifier })
        let missingApps = apps.filter { !representedPIDs.contains($0.processIdentifier) }
        guard !missingApps.isEmpty else {
            BokslTabDiagnosticLog.debug("window-catalog.ax-only skipped reason=no-missing-apps apps=\(apps.count)")
            return []
        }

        let axOnlySnapshots = AXOnlyWindowCatalogPolicy.snapshotsForAppsWithoutCGWindows(
            apps: missingApps,
            axSnapshotsByPID: axSnapshotsByPID
        )
        let includedByPID = Dictionary(grouping: axOnlySnapshots, by: { $0.identity.ownerProcessIdentifier })
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-only missingApps=\(missingApps.count) fetchedPIDs=\(axSnapshotsByPID.count) included=\(axOnlySnapshots.count)"
        )
        missingApps.forEach { app in
            let axCount = axSnapshotsByPID[app.processIdentifier]?.count ?? 0
            let includedCount = includedByPID[app.processIdentifier]?.count ?? 0
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-only.app pid=\(app.processIdentifier) name=\(app.displayName.catalogDiagnosticValue) axSnapshots=\(axCount) included=\(includedCount)"
            )
        }
        axOnlySnapshots.forEach { snapshot in
            BokslTabDiagnosticLog.debug("window-catalog.ax-only.include \(snapshot.diagnosticDescription)")
        }
        return axOnlySnapshots
    }

    private func accessibilityEventCachedSnapshotsForEligibleApps(
        includedSnapshots: [WindowSnapshot],
        eligiblePIDs: Set<Int32>
    ) -> [WindowSnapshot] {
        guard isAccessibilityTrusted() else {
            BokslTabDiagnosticLog.debug("window-catalog.ax-event-cache skipped reason=accessibility-untrusted")
            return []
        }

        guard !eligiblePIDs.isEmpty else {
            BokslTabDiagnosticLog.debug("window-catalog.ax-event-cache skipped reason=no-eligible-apps")
            return []
        }

        let snapshots = accessibilityEventCache.snapshots(
            for: eligiblePIDs,
            excluding: includedSnapshots
        )
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event-cache eligiblePIDs=\(eligiblePIDs.sorted().map(String.init).joined(separator: ",")) included=\(snapshots.count)"
        )
        snapshots.forEach { snapshot in
            BokslTabDiagnosticLog.debug("window-catalog.ax-event-cache.include \(snapshot.diagnosticDescription)")
        }
        return snapshots
    }

    private func tabExpansionEligibilityByPID(
        for snapshots: [WindowSnapshot],
        apps: [AppIdentity]
    ) -> [Int32: AppTabExpansionEligibilityDecision] {
        var decisions: [Int32: AppTabExpansionEligibilityDecision] = [:]
        for snapshot in snapshots where decisions[snapshot.identity.ownerProcessIdentifier] == nil {
            let runningApp = NSRunningApplication(processIdentifier: snapshot.identity.ownerProcessIdentifier)
            decisions[snapshot.identity.ownerProcessIdentifier] = AppTabExpansionEligibilityPolicy.decision(
                for: AppTabExpansionAppDescriptor(
                    bundleIdentifier: runningApp?.bundleIdentifier,
                    ownerName: snapshot.ownerName,
                    localizedName: runningApp?.localizedName
                )
            )
        }
        for app in apps where decisions[app.processIdentifier] == nil {
            decisions[app.processIdentifier] = AppTabExpansionEligibilityPolicy.decision(
                for: AppTabExpansionAppDescriptor(
                    bundleIdentifier: app.bundleIdentifier,
                    ownerName: app.processName,
                    localizedName: app.localizedName
                )
            )
        }
        return decisions
    }

    private func accessibilityEventObserverDescriptors(
        snapshots: [WindowSnapshot],
        apps: [AppIdentity],
        eligibilityByPID: [Int32: AppTabExpansionEligibilityDecision]
    ) -> [AccessibilityEventObservedAppDescriptor] {
        let snapshotDescriptors = snapshots.compactMap { snapshot -> AccessibilityEventObservedAppDescriptor? in
            guard eligibilityByPID[snapshot.identity.ownerProcessIdentifier]?.canExpandTabs == true else {
                return nil
            }
            return AccessibilityEventObservedAppDescriptor(
                processIdentifier: snapshot.identity.ownerProcessIdentifier,
                ownerName: snapshot.ownerName
            )
        }
        let appDescriptors = apps.compactMap { app -> AccessibilityEventObservedAppDescriptor? in
            guard eligibilityByPID[app.processIdentifier]?.canExpandTabs == true else { return nil }
            return AccessibilityEventObservedAppDescriptor(
                processIdentifier: app.processIdentifier,
                ownerName: app.displayName
            )
        }

        var descriptorsByPID: [Int32: AccessibilityEventObservedAppDescriptor] = [:]
        for descriptor in snapshotDescriptors + appDescriptors {
            descriptorsByPID[descriptor.processIdentifier] = descriptor
        }
        return descriptorsByPID.values.sorted { $0.processIdentifier < $1.processIdentifier }
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
