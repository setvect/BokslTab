import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSWindowCatalogProvider: WindowCatalogProviding, WindowCatalogRefreshing {
    private let accessibility: MacOSAccessibilityService
    private var seenWindows: SeenWindowRegistry { accessibility.knownWindows }
    private let windowInfoList: () -> [[String: Any]]?
    private let windowInfoForWindowID: (UInt32) -> [String: Any]?
    private let isAccessibilityTrusted: () -> Bool
    private let accessibilitySnapshotLoader: ((Int32, Bool) -> [AccessibilityWindowSnapshot]?)?
    private let accessibilityEventObserver: AccessibilityWindowEventObserver
    private let accessibilityCache: BackgroundRefreshCache<Int32, [AccessibilityWindowSnapshot]>
    private let now: () -> TimeInterval

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
        windowInfoForWindowID: @escaping (UInt32) -> [String: Any]? = WindowServerWindowAccess.live.windowInfo,
        isAccessibilityTrusted: @escaping () -> Bool = AXIsProcessTrusted,
        accessibilitySnapshotLoader: ((Int32, Bool) -> [AccessibilityWindowSnapshot]?)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.accessibility = accessibility
        self.windowInfoList = windowInfoList
        self.windowInfoForWindowID = windowInfoForWindowID
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.accessibilitySnapshotLoader = accessibilitySnapshotLoader
        self.accessibilityEventObserver = accessibility.eventObserver
        self.accessibilityCache = BackgroundRefreshCache(queue: accessibility.workerQueue, now: now)
        self.now = now
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
        let requestedPIDs = Set(snapshots.map { $0.identity.ownerProcessIdentifier })
            .union(apps.map(\.processIdentifier))
        accessibilityCache.retainOnly(accessibilityTrusted ? requestedPIDs : [])
        accessibility.retainOnly(accessibilityTrusted ? requestedPIDs : [])
        if accessibilityTrusted {
            let descriptors = accessibilityEventObserverDescriptors(
                snapshots: snapshots,
                apps: apps,
                eligibilityByPID: tabExpansionEligibilityByPID
            )
            accessibilityEventObserver.scheduleObserverPruning(to: Set(descriptors.map(\.processIdentifier)))
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
                            for: pid,
                            resolveTabs: tabResolutionEligiblePIDs.contains(pid),
                            query: query,
                            elementCache: self.accessibility.windowElements
                        )
                        if let descriptor = descriptorsByPID[pid] {
                            self.accessibilityEventObserver.ensureObserver(for: descriptor, query: query)
                            self.accessibilityEventObserver.recordCurrentWindows(for: pid, query: query)
                        }
                        return snapshots
                    }
                }
            }
        } else {
            accessibilityEventObserver.scheduleObserverPruning(to: [])
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
            accessibilityCache.retainOnly([])
            accessibility.retainOnly([])
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
        // Details can leave out a window that is on screen (taken in another Space, or before a tab
        // switch). Its own remembered title keeps the row and keeps it from looking like a duplicate.
        let knownTitleSnapshots = seenWindows.applyExpectedTabTitles(
            to: seenWindows.applyRememberedTitles(to: enrichedSnapshots),
            now: now()
        )
        let filteredSnapshots = filterLikelyDuplicateUntitledSnapshots(knownTitleSnapshots)
        let axOnlySnapshots = accessibilityOnlySnapshotsForAppsWithoutCGWindows(
            apps,
            includedSnapshots: filteredSnapshots,
            axSnapshotsByPID: axSnapshotsByPID
        )
        if accessibilityTrusted {
            // Details may be older than what is on screen, so a row seen now has the last word.
            seenWindows.applyAccessibilityState(axSnapshotsByPID)
            seenWindows.recordOnScreen(knownTitleSnapshots)
        }
        let tabs = nativeTabMatcher(
            onScreenSnapshots: filteredSnapshots,
            axSnapshotsByPID: axSnapshotsByPID,
            tabExpansionEligibilityByPID: tabExpansionEligibilityByPID,
            accessibilityTrusted: accessibilityTrusted
        )
        let rememberedSnapshots = rememberedSnapshotsNotOnScreen(
            apps: apps,
            onScreenSnapshots: snapshots,
            includedSnapshots: filteredSnapshots + axOnlySnapshots,
            tabs: tabs,
            accessibilityTrusted: accessibilityTrusted
        )
        let unseenTabSnapshots = tabs.unclaimedTabSnapshots()
        let resultSnapshots = filteredSnapshots + axOnlySnapshots + rememberedSnapshots + unseenTabSnapshots
        BokslTabDiagnosticLog.debug(
            "window-catalog.result candidates=\(snapshots.count) enriched=\(enrichedSnapshots.count) cgIncluded=\(filteredSnapshots.count) axOnly=\(axOnlySnapshots.count) remembered=\(rememberedSnapshots.count) unseenTabs=\(unseenTabSnapshots.count) included=\(resultSnapshots.count)"
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
                let matchKind = axSnapshots[axIndex].windowID == nil ? "geometry" : "window-id"
                BokslTabDiagnosticLog.debug(
                    "window-catalog.ax.match cgWindow=\(enrichedSnapshots[snapshotIndex].identity.windowID) pid=\(processIdentifier) axIndex=\(axIndex) by=\(matchKind) title=\(enrichedSnapshots[snapshotIndex].identity.title.catalogDiagnosticValue)"
                )
            }

            let weakTitleSnapshotIndices = snapshotIndices.filter {
                WindowTitleFallbackCandidatePolicy.needsAccessibilityFallback(enrichedSnapshots[$0])
            }
            // An identified AX window that matched nothing is some other window (minimized, another Space).
            // Only unidentified windows may lend their titles to the remaining weak-titled CG windows.
            let availableTitles = axSnapshots.indices
                .filter { !usedAXIndices.contains($0) && axSnapshots[$0].windowID == nil }
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

        // Details are kept until newer ones arrive, so a window may have been closed since they were read.
        let existingAXSnapshotsByPID = Dictionary(uniqueKeysWithValues: missingApps.map { app in
            (app.processIdentifier, (axSnapshotsByPID[app.processIdentifier] ?? []).filter { snapshot in
                guard let windowID = snapshot.windowID else { return true }
                return WindowServerPlacement(
                    windowInfo: windowInfoForWindowID(windowID),
                    processIdentifier: app.processIdentifier
                ) != .missing
            })
        })
        let axOnlySnapshots = AXOnlyWindowCatalogPolicy.snapshotsForAppsWithoutCGWindows(
            apps: missingApps,
            axSnapshotsByPID: existingAXSnapshotsByPID
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

    /// Windows seen before that still exist but are not on screen: on another desktop, in a
    /// full-screen Space, or an unselected tab of a native tab group. They keep their window number,
    /// so the row is the same one as when the window was on screen.
    private func rememberedSnapshotsNotOnScreen(
        apps: [AppIdentity],
        onScreenSnapshots: [WindowSnapshot],
        includedSnapshots: [WindowSnapshot],
        tabs: NativeTabMatcher,
        accessibilityTrusted: Bool
    ) -> [WindowSnapshot] {
        guard accessibilityTrusted, !apps.isEmpty else { return [] }

        let snapshots = seenWindows.offScreenSnapshots(
            processIdentifiers: Set(apps.map(\.processIdentifier)),
            excludingWindowIDs: Set((onScreenSnapshots + includedSnapshots).map(\.identity.windowID)),
            windowInfo: windowInfoForWindowID,
            isUnselectedTab: { entry in
                tabs.claimTab(processIdentifier: entry.processIdentifier, keys: entry.tabKeys)
            }
        )
        BokslTabDiagnosticLog.debug(
            "window-catalog.remembered known=\(seenWindows.count) included=\(snapshots.count) windows=\(snapshots.map { String($0.identity.windowID) }.joined(separator: ","))"
        )
        return snapshots
    }

    /// The tab bars of apps with native window tabs, as last read through AX. Each tab is another
    /// window of the app; the on-screen window of a group claims its own tab here.
    private func nativeTabMatcher(
        onScreenSnapshots: [WindowSnapshot],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]],
        tabExpansionEligibilityByPID: [Int32: AppTabExpansionEligibilityDecision],
        accessibilityTrusted: Bool
    ) -> NativeTabMatcher {
        guard accessibilityTrusted else { return NativeTabMatcher() }

        var groups: [NativeTabMatcher.Group] = []
        for (processIdentifier, axSnapshots) in axSnapshotsByPID
        where tabExpansionEligibilityByPID[processIdentifier]?.canExpandTabs == true {
            let rows = onScreenSnapshots.filter { $0.identity.ownerProcessIdentifier == processIdentifier }
            guard !rows.isEmpty else { continue }
            let keysByWindowID = seenWindows.tabKeys(
                windowIDs: rows.map(\.identity.windowID),
                processIdentifier: processIdentifier
            )
            for axSnapshot in axSnapshots where axSnapshot.tabs.count > 1 {
                guard let group = NativeTabMatcher.Group(
                    tabBar: axSnapshot,
                    onScreenRows: rows,
                    rememberedKeysByWindowID: keysByWindowID,
                    isOrderedOut: { windowID in
                        WindowServerPlacement(
                            windowInfo: self.windowInfoForWindowID(windowID),
                            processIdentifier: processIdentifier
                        ) == .orderedOut
                    }
                ) else { continue }
                groups.append(group)
                BokslTabDiagnosticLog.debug(
                    "window-catalog.tabs pid=\(processIdentifier) window=\(group.parent.identity.windowID) tabBarWindow=\(axSnapshot.windowID.map(String.init) ?? "nil") count=\(axSnapshot.tabs.count) source=\(axSnapshot.tabSource?.rawValue ?? "unknown")"
                )
            }
        }
        return NativeTabMatcher(groups: groups)
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
