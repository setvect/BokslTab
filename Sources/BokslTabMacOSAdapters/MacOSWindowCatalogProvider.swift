import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSWindowCatalogProvider: WindowCatalogProviding {
    private let titleCache = WindowTitleCache()
    private let accessibilityEventCache: AccessibilityWindowEventCache

    public init() {
        self.accessibilityEventCache = .shared
    }

    init(accessibilityEventCache: AccessibilityWindowEventCache) {
        self.accessibilityEventCache = accessibilityEventCache
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

        let tabExpansionEligibilityByPID = tabExpansionEligibilityByPID(for: snapshots, apps: apps)
        let tabResolutionEligiblePIDs = Set(
            tabExpansionEligibilityByPID.compactMap { processIdentifier, decision in
                decision.canExpandTabs ? processIdentifier : nil
            }
        )
        let accessibilityTrusted = AXIsProcessTrusted()
        if accessibilityTrusted {
            accessibilityEventCache.refreshObservers(
                for: accessibilityEventObserverDescriptors(
                    snapshots: snapshots,
                    apps: apps,
                    eligibilityByPID: tabExpansionEligibilityByPID
                )
            )
            accessibilityEventCache.seedCurrentWindows(for: tabResolutionEligiblePIDs)
        }
        let axSnapshotsByPID = accessibilityTrusted
            ? accessibilityWindowSnapshotsByPID(
                Set(snapshots.map { $0.identity.ownerProcessIdentifier }),
                tabResolutionEligiblePIDs: tabResolutionEligiblePIDs
            )
            : [:]
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
            includedSnapshots: tabExpandedSnapshots
        )
        let accessibilityEventSnapshots = accessibilityEventCachedSnapshotsForEligibleApps(
            includedSnapshots: tabExpandedSnapshots + axOnlySnapshots,
            eligiblePIDs: tabResolutionEligiblePIDs
        )
        let liveSnapshots = tabExpandedSnapshots + axOnlySnapshots + accessibilityEventSnapshots
        titleCache.record(filteredSnapshots + axOnlySnapshots)
        let cachedSnapshots = cachedTitleSnapshotsForAppsWithoutWindows(
            apps,
            includedSnapshots: liveSnapshots
        )
        let resultSnapshots = liveSnapshots + cachedSnapshots
        BokslTabDiagnosticLog.write(
            "window-catalog.result candidates=\(snapshots.count) enriched=\(enrichedSnapshots.count) cgIncluded=\(filteredSnapshots.count) tabExpanded=\(tabExpandedSnapshots.count) axOnly=\(axOnlySnapshots.count) axEventCached=\(accessibilityEventSnapshots.count) cached=\(cachedSnapshots.count) included=\(resultSnapshots.count)"
        )
        resultSnapshots.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.include \(snapshot.diagnosticDescription)")
        }
        return resultSnapshots.map(\.identity)
    }

    private func enrichTitlesFromAccessibilityIfPossible(
        _ snapshots: [WindowSnapshot],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]]
    ) -> [WindowSnapshot] {
        guard AXIsProcessTrusted() else {
            BokslTabDiagnosticLog.write("window-catalog.ax skipped reason=accessibility-untrusted snapshots=\(snapshots.count)")
            return snapshots
        }

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

    private func expandWindowTabsIfPossible(
        _ snapshots: [WindowSnapshot],
        axSnapshotsByPID: [Int32: [AccessibilityWindowSnapshot]],
        tabExpansionEligibilityByPID: [Int32: AppTabExpansionEligibilityDecision]
    ) -> [WindowSnapshot] {
        guard AXIsProcessTrusted() else {
            BokslTabDiagnosticLog.write("window-catalog.ax.tabs.skip reason=accessibility-untrusted snapshots=\(snapshots.count)")
            return snapshots
        }

        guard !axSnapshotsByPID.isEmpty else {
            BokslTabDiagnosticLog.write("window-catalog.ax.tabs.skip reason=no-ax-snapshots snapshots=\(snapshots.count)")
            return snapshots
        }

        return snapshots.flatMap { snapshot -> [WindowSnapshot] in
            let eligibility = tabExpansionEligibilityByPID[snapshot.identity.ownerProcessIdentifier]
            guard eligibility?.canExpandTabs == true else {
                BokslTabDiagnosticLog.write(
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
                BokslTabDiagnosticLog.write(
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
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.tabs app=\(snapshot.ownerName.catalogDiagnosticValue) pid=\(snapshot.identity.ownerProcessIdentifier) window=\(snapshot.identity.windowID) source=\(axSnapshot.tabSource?.rawValue ?? "unknown") count=\(axSnapshot.tabs.count) titled=\(titledCount) selected=\(selected.map(String.init) ?? "nil") durationMs=\(axSnapshot.tabDurationMs)"
                )
            } else {
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.tabs.skip reason=\(result.fallbackReason ?? axSnapshot.tabSkipReason ?? "no-tabs") pid=\(snapshot.identity.ownerProcessIdentifier) window=\(snapshot.identity.windowID) source=\(axSnapshot.tabSource?.rawValue ?? "missing") durationMs=\(axSnapshot.tabDurationMs)"
                )
            }
            return result.snapshots
        }
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
            Set(missingApps.map(\.processIdentifier)),
            tabResolutionEligiblePIDs: []
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

    private func accessibilityEventCachedSnapshotsForEligibleApps(
        includedSnapshots: [WindowSnapshot],
        eligiblePIDs: Set<Int32>
    ) -> [WindowSnapshot] {
        guard AXIsProcessTrusted() else {
            BokslTabDiagnosticLog.write("window-catalog.ax-event-cache skipped reason=accessibility-untrusted")
            return []
        }

        guard !eligiblePIDs.isEmpty else {
            BokslTabDiagnosticLog.write("window-catalog.ax-event-cache skipped reason=no-eligible-apps")
            return []
        }

        let snapshots = accessibilityEventCache.snapshots(
            for: eligiblePIDs,
            excluding: includedSnapshots
        )
        BokslTabDiagnosticLog.write(
            "window-catalog.ax-event-cache eligiblePIDs=\(eligiblePIDs.sorted().map(String.init).joined(separator: ",")) included=\(snapshots.count)"
        )
        snapshots.forEach { snapshot in
            BokslTabDiagnosticLog.write("window-catalog.ax-event-cache.include \(snapshot.diagnosticDescription)")
        }
        return snapshots
    }

    private func accessibilityWindowSnapshotsByPID(
        _ processIdentifiers: Set<Int32>,
        tabResolutionEligiblePIDs: Set<Int32>
    ) -> [Int32: [AccessibilityWindowSnapshot]] {
        var snapshotsByPID: [Int32: [AccessibilityWindowSnapshot]] = [:]

        for processIdentifier in processIdentifiers {
            let shouldResolveTabs = tabResolutionEligiblePIDs.contains(processIdentifier)
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
            let supplementalWindows = supplementalAccessibilityWindows(
                from: appElement,
                processIdentifier: processIdentifier
            )

            let snapshots = AccessibilityWindowSnapshot.deduplicated(
                (axWindows + supplementalWindows).compactMap { window in
                    AccessibilityWindowSnapshot(window: window, resolveTabs: shouldResolveTabs)
                }
            )
            if !snapshots.isEmpty {
                snapshotsByPID[processIdentifier] = snapshots
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.fetch pid=\(processIdentifier) raw=\(axWindows.count) supplemental=\(supplementalWindows.count) snapshots=\(snapshots.count) tabResolution=\(shouldResolveTabs ? "enabled" : "disabled")"
                )
            } else {
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax.fetch pid=\(processIdentifier) raw=\(axWindows.count) supplemental=\(supplementalWindows.count) snapshots=0 error=\(windowsError.rawValue) tabResolution=\(shouldResolveTabs ? "enabled" : "disabled")"
                )
            }
        }

        return snapshotsByPID
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

struct AppTabExpansionEligibilityPolicy {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.google.android.studio"
    ]

    private static let supportedBundleIdentifierPrefixes = [
        "com.jetbrains."
    ]

    private static let supportedNameFragments = [
        "IntelliJ IDEA",
        "WebStorm",
        "PyCharm",
        "PhpStorm",
        "GoLand",
        "CLion",
        "RubyMine",
        "DataGrip",
        "Rider",
        "AppCode",
        "Android Studio",
        "Finder"
    ]

    static func canExpandTabs(ownerName: String?) -> Bool {
        decision(for: AppTabExpansionAppDescriptor(ownerName: ownerName)).canExpandTabs
    }

    static func decision(for app: AppTabExpansionAppDescriptor) -> AppTabExpansionEligibilityDecision {
        if let bundleIdentifier = app.bundleIdentifier?.nonBlankCatalogTitle?.lowercased() {
            if supportedBundleIdentifiers.contains(bundleIdentifier) {
                return AppTabExpansionEligibilityDecision(canExpandTabs: true, skipReason: nil)
            }
            if supportedBundleIdentifierPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
                return AppTabExpansionEligibilityDecision(canExpandTabs: true, skipReason: nil)
            }
        }

        let appNames = [app.ownerName, app.localizedName].compactMap { $0?.nonBlankCatalogTitle }
        if appNames.contains(where: isSupportedAppName) {
            return AppTabExpansionEligibilityDecision(canExpandTabs: true, skipReason: nil)
        }

        return AppTabExpansionEligibilityDecision(
            canExpandTabs: false,
            skipReason: "unsupported-app-for-window-tabs"
        )
    }

    private static func isSupportedAppName(_ appName: String) -> Bool {
        supportedNameFragments.contains { fragment in
            appName.localizedCaseInsensitiveContains(fragment)
        }
    }
}

struct AppTabExpansionAppDescriptor {
    let bundleIdentifier: String?
    let ownerName: String?
    let localizedName: String?

    init(
        bundleIdentifier: String? = nil,
        ownerName: String? = nil,
        localizedName: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.localizedName = localizedName
    }
}

struct AppTabExpansionEligibilityDecision {
    let canExpandTabs: Bool
    let skipReason: String?
}

enum AccessibilityTabSource: String {
    case windowTabs = "window-tabs"
}

struct AccessibilityTabSnapshot: Equatable {
    let index: Int
    let title: String?
    let isSelected: Bool
    let source: AccessibilityTabSource
}

struct AccessibilityTabResolution {
    let tabs: [AccessibilityTabSnapshot]
    let source: AccessibilityTabSource?
    let skipReason: String?
    let durationMs: Int
}

struct AccessibilityTabResolver {
    static func resolveTabs(in window: AXUIElement) -> AccessibilityTabResolution {
        let startedAt = CFAbsoluteTimeGetCurrent()
        var rawTabs: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, kAXTabsAttribute as CFString, &rawTabs)
        guard error == .success else {
            return AccessibilityTabResolution(
                tabs: [],
                source: nil,
                skipReason: "direct-axtabs-unavailable",
                durationMs: elapsedMs(since: startedAt)
            )
        }
        guard let tabElements = rawTabs as? [AXUIElement], !tabElements.isEmpty else {
            return AccessibilityTabResolution(
                tabs: [],
                source: .windowTabs,
                skipReason: "no-tabs",
                durationMs: elapsedMs(since: startedAt)
            )
        }

        return AccessibilityTabResolution(
            tabs: snapshots(from: tabElements, source: .windowTabs),
            source: .windowTabs,
            skipReason: nil,
            durationMs: elapsedMs(since: startedAt)
        )
    }

    private static func snapshots(
        from tabElements: [AXUIElement],
        source: AccessibilityTabSource
    ) -> [AccessibilityTabSnapshot] {
        tabElements.enumerated().map { index, element in
            AccessibilityTabSnapshot(
                index: index,
                title: title(of: element),
                isSelected: isSelected(element),
                source: source
            )
        }
    }

    static func title(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var rawTitle: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawTitle) == .success else {
                continue
            }
            if let title = rawTitle as? String, let normalized = title.nonBlankCatalogTitle {
                return normalized
            }
        }
        return nil
    }

    static func isSelected(_ element: AXUIElement) -> Bool {
        var rawSelected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &rawSelected) == .success else {
            return false
        }
        if let selected = rawSelected as? Bool { return selected }
        if let selected = rawSelected as? NSNumber { return selected.boolValue }
        return false
    }

    private static func elapsedMs(since startedAt: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000).rounded())
    }
}

struct TabExpansionResult {
    let snapshots: [WindowSnapshot]
    let didExpand: Bool
    let fallbackReason: String?
}

struct TabExpandedWindowCatalogPolicy {
    static func expand(
        snapshot: WindowSnapshot,
        tabs: [AccessibilityTabSnapshot],
        parentFrame: WindowFrameIdentity? = nil
    ) -> TabExpansionResult {
        guard tabs.count > 1 else {
            return TabExpansionResult(snapshots: [snapshot], didExpand: false, fallbackReason: "single-tab")
        }

        let usableTabs = tabs.compactMap { tab -> (AccessibilityTabSnapshot, String)? in
            guard let title = usableTitle(tab.title) else { return nil }
            return (tab, title)
        }
        guard usableTabs.count >= 2 else {
            return TabExpansionResult(snapshots: [snapshot], didExpand: false, fallbackReason: "placeholder-title")
        }

        let expanded = usableTabs.map { tab, title in
            WindowSnapshot(
                identity: WindowIdentity(
                    windowID: snapshot.identity.windowID,
                    ownerProcessIdentifier: snapshot.identity.ownerProcessIdentifier,
                    title: title,
                    tab: WindowTabIdentity(
                        parentWindowID: snapshot.identity.windowID,
                        parentTitle: snapshot.identity.title?.nonBlankCatalogTitle,
                        parentFrame: parentFrame,
                        index: tab.index,
                        title: title,
                        isSelected: tab.isSelected
                    )
                ),
                bounds: snapshot.bounds,
                ownerName: snapshot.ownerName
            )
        }
        return TabExpansionResult(snapshots: expanded, didExpand: true, fallbackReason: nil)
    }

    static func usableTitle(_ title: String?) -> String? {
        guard let title = title?.nonBlankCatalogTitle,
              !isPlaceholderTitle(title)
        else { return nil }
        return title
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        if normalized.range(of: #"^창\s*\d+$"#, options: [.regularExpression]) != nil { return true }
        if normalized.range(of: #"^Window\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }
}

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

        return entries
            .filter { eligiblePIDs.contains($0.processIdentifier) }
            .filter { entry in
                guard WindowSnapshot.isReasonableWindowBounds(entry.frame),
                      !TabExpandedWindowCatalogPolicy.isPlaceholderTitle(entry.title)
                else { return false }

                let key = WindowKey(entry: entry)
                return !includedWindowKeys.contains(key)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { entry in
                WindowSnapshot(
                    identity: WindowIdentity(
                        windowID: entry.windowID,
                        ownerProcessIdentifier: entry.processIdentifier,
                        title: entry.title
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

final class AccessibilityWindowEventCache {
    static let shared = AccessibilityWindowEventCache()

    private struct StoredWindow {
        let entry: AccessibilityEventWindowCacheEntry
        let element: AXUIElement
    }

    private struct ObserverRegistration {
        let observer: AXObserver
        let appElement: AXUIElement
        let source: CFRunLoopSource
    }

    private static let notifications: [CFString] = [
        kAXMainWindowChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString
    ]
    private static let maximumEntriesPerProcess = 32

    private let lock = NSLock()
    private var windowsByPID: [Int32: [UInt32: StoredWindow]] = [:]
    private var observersByPID: [Int32: ObserverRegistration] = [:]
    private var ownerNameByPID: [Int32: String] = [:]

    func refreshObservers(for descriptors: [AccessibilityEventObservedAppDescriptor]) {
        guard AXIsProcessTrusted() else {
            removeAllObservers(reason: "accessibility-untrusted")
            return
        }

        let desiredPIDs = Set(descriptors.map(\.processIdentifier))
        removeObserversMissing(from: desiredPIDs)

        for descriptor in descriptors {
            if let ownerName = descriptor.ownerName {
                setOwnerName(ownerName, for: descriptor.processIdentifier)
            }
            guard observersByPID[descriptor.processIdentifier] == nil else { continue }
            addObserver(for: descriptor)
        }
    }

    func seedCurrentWindows(for processIdentifiers: Set<Int32>) {
        guard AXIsProcessTrusted(), !processIdentifiers.isEmpty else { return }
        for processIdentifier in processIdentifiers.sorted() {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let windows = currentWindows(from: appElement, processIdentifier: processIdentifier)
            record(windows: windows, processIdentifier: processIdentifier, source: "seed")
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-event-cache.seed pid=\(processIdentifier) windows=\(windows.count)"
            )
        }
    }

    func snapshots(
        for eligiblePIDs: Set<Int32>,
        excluding includedSnapshots: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        let entries = cachedEntries()
        return AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: eligiblePIDs,
            excluding: includedSnapshots
        )
    }

    func window(matching window: WindowIdentity, app: AppIdentity) -> AXUIElement? {
        lock.lock()
        let storedWindows = windowsByPID[app.processIdentifier].map { Array($0.values) } ?? []
        lock.unlock()

        guard !storedWindows.isEmpty else { return nil }
        if let exact = storedWindows.first(where: { $0.entry.windowID == window.windowID }) {
            return exact.element
        }

        guard let targetTitle = window.title?.nonBlankCatalogTitle else { return nil }
        let titleMatches = storedWindows.filter {
            $0.entry.title.nonBlankCatalogTitle == targetTitle
        }
        guard titleMatches.count == 1 else { return nil }
        return titleMatches[0].element
    }

    private func addObserver(for descriptor: AccessibilityEventObservedAppDescriptor) {
        let appElement = AXUIElementCreateApplication(descriptor.processIdentifier)
        var rawObserver: AXObserver?
        let createError = AXObserverCreate(
            descriptor.processIdentifier,
            AccessibilityWindowEventCache.observerCallback,
            &rawObserver
        )
        guard createError == .success, let observer = rawObserver else {
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-event-cache.observer failed pid=\(descriptor.processIdentifier) error=\(createError.rawValue)"
            )
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var addedNotifications: [String] = []
        for notification in Self.notifications {
            let addError = AXObserverAddNotification(observer, appElement, notification, refcon)
            if addError == .success {
                addedNotifications.append(notification as String)
            } else {
                BokslTabDiagnosticLog.write(
                    "window-catalog.ax-event-cache.notification failed pid=\(descriptor.processIdentifier) name=\(notification) error=\(addError.rawValue)"
                )
            }
        }

        guard !addedNotifications.isEmpty else {
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-event-cache.observer skipped pid=\(descriptor.processIdentifier) reason=no-notifications"
            )
            return
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observersByPID[descriptor.processIdentifier] = ObserverRegistration(
            observer: observer,
            appElement: appElement,
            source: source
        )
        BokslTabDiagnosticLog.write(
            "window-catalog.ax-event-cache.observer added pid=\(descriptor.processIdentifier) notifications=\(addedNotifications.joined(separator: ","))"
        )
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let cache = Unmanaged<AccessibilityWindowEventCache>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        cache.handleEvent(element: element, notification: notification as String)
    }

    private func handleEvent(element: AXUIElement, notification: String) {
        var processIdentifier: pid_t = 0
        let pidError = AXUIElementGetPid(element, &processIdentifier)
        guard pidError == .success, processIdentifier > 0 else {
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-event-cache.event skipped notification=\(notification) reason=pid-unavailable error=\(pidError.rawValue)"
            )
            return
        }

        let pid = Int32(processIdentifier)
        var windows: [AXUIElement] = []
        if isWindowElement(element) {
            windows.append(element)
        }
        windows.append(contentsOf: currentWindows(
            from: AXUIElementCreateApplication(pid),
            processIdentifier: pid
        ))
        let uniqueWindows = deduplicatedElements(windows)
        record(windows: uniqueWindows, processIdentifier: pid, source: notification)
        BokslTabDiagnosticLog.write(
            "window-catalog.ax-event-cache.event notification=\(notification) pid=\(pid) windows=\(uniqueWindows.count)"
        )
    }

    private func currentWindows(
        from appElement: AXUIElement,
        processIdentifier: Int32
    ) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        var rawWindows: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        )
        if windowsError == .success, let axWindows = rawWindows as? [AXUIElement] {
            windows.append(contentsOf: axWindows)
        }

        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var rawWindow: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &rawWindow)
            guard error == .success,
                  let rawWindow,
                  CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
            else { continue }
            windows.append(rawWindow as! AXUIElement)
        }

        let uniqueWindows = deduplicatedElements(windows)
        BokslTabDiagnosticLog.write(
            "window-catalog.ax-event-cache.current pid=\(processIdentifier) raw=\(windows.count) unique=\(uniqueWindows.count)"
        )
        return uniqueWindows
    }

    private func record(
        windows: [AXUIElement],
        processIdentifier: Int32,
        source: String
    ) {
        let now = Date()
        for window in windows {
            guard let entry = cacheEntry(
                for: window,
                processIdentifier: processIdentifier,
                source: source,
                updatedAt: now
            ) else { continue }
            lock.lock()
            var entries = windowsByPID[processIdentifier] ?? [:]
            entries[entry.windowID] = StoredWindow(entry: entry, element: window)
            windowsByPID[processIdentifier] = prune(entries)
            lock.unlock()
            BokslTabDiagnosticLog.write(
                "window-catalog.ax-event-cache.record pid=\(processIdentifier) window=\(entry.windowID) source=\(source) title=\(entry.title.catalogDiagnosticValue) frame=\(entry.frame.catalogDiagnosticDescription)"
            )
        }
    }

    private func cacheEntry(
        for window: AXUIElement,
        processIdentifier: Int32,
        source: String,
        updatedAt: Date
    ) -> AccessibilityEventWindowCacheEntry? {
        guard let title = AccessibilityWindowSnapshot.title(of: window)?.nonBlankCatalogTitle,
              !TabExpandedWindowCatalogPolicy.isPlaceholderTitle(title),
              let frame = CGRect.fromAccessibilityWindow(window),
              WindowSnapshot.isReasonableWindowBounds(frame)
        else { return nil }

        let windowID = SyntheticWindowID.accessibilityEvent(
            processIdentifier: processIdentifier,
            title: title,
            frame: frame,
            index: 0
        )
        return AccessibilityEventWindowCacheEntry(
            processIdentifier: processIdentifier,
            windowID: windowID,
            title: title,
            frame: frame,
            ownerName: ownerName(for: processIdentifier),
            source: source,
            updatedAt: updatedAt
        )
    }

    private func cachedEntries() -> [AccessibilityEventWindowCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        return windowsByPID.values.flatMap { $0.values.map(\.entry) }
    }

    private func setOwnerName(_ ownerName: String, for processIdentifier: Int32) {
        lock.lock()
        ownerNameByPID[processIdentifier] = ownerName
        lock.unlock()
    }

    private func ownerName(for processIdentifier: Int32) -> String? {
        lock.lock()
        let cached = ownerNameByPID[processIdentifier]
        lock.unlock()
        if let cached { return cached }
        return NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
            ?? NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
    }

    private func prune(_ entries: [UInt32: StoredWindow]) -> [UInt32: StoredWindow] {
        guard entries.count > Self.maximumEntriesPerProcess else { return entries }
        let kept = entries.values
            .sorted { lhs, rhs in lhs.entry.updatedAt > rhs.entry.updatedAt }
            .prefix(Self.maximumEntriesPerProcess)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.entry.windowID, $0) })
    }

    private func removeObserversMissing(from desiredPIDs: Set<Int32>) {
        let stalePIDs = observersByPID.keys.filter { !desiredPIDs.contains($0) }
        for processIdentifier in stalePIDs {
            removeObserver(processIdentifier: processIdentifier, reason: "not-eligible")
        }
    }

    private func removeAllObservers(reason: String) {
        for processIdentifier in observersByPID.keys {
            removeObserver(processIdentifier: processIdentifier, reason: reason)
        }
    }

    private func removeObserver(processIdentifier: Int32, reason: String) {
        guard let registration = observersByPID.removeValue(forKey: processIdentifier) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .commonModes)
        BokslTabDiagnosticLog.write(
            "window-catalog.ax-event-cache.observer removed pid=\(processIdentifier) reason=\(reason)"
        )
    }

    private func isWindowElement(_ element: AXUIElement) -> Bool {
        var rawRole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
              let role = rawRole as? String
        else { return false }
        return role == kAXWindowRole
    }

    private func deduplicatedElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<String>()
        return elements.filter { element in
            let title = AccessibilityWindowSnapshot.title(of: element)?.nonBlankCatalogTitle ?? ""
            let frame = CGRect.fromAccessibilityWindow(element)?.catalogDiagnosticDescription ?? ""
            let key = "\(title)|\(frame)"
            return seen.insert(key).inserted
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
    static func accessibilityEvent(
        processIdentifier: Int32,
        title: String,
        frame: CGRect,
        index: Int
    ) -> UInt32 {
        0x2000_0000 | (hash(
            processIdentifier: processIdentifier,
            title: title,
            frame: frame,
            index: index
        ) & 0x1fff_ffff)
    }

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
                title: title,
                tab: identity.tab
            ),
            bounds: bounds,
            ownerName: ownerName
        )
    }

    static func isReasonableWindowBounds(_ bounds: CGRect) -> Bool {
        bounds.width >= 40 && bounds.height >= 40
    }

    var diagnosticDescription: String {
        if let tab = identity.tab {
            let titleLength = identity.title?.count ?? 0
            return "window=\(identity.windowID) pid=\(identity.ownerProcessIdentifier) owner=\(ownerName.catalogDiagnosticValue) title=<redacted> tabTitleKnown=\(identity.title?.nonBlankCatalogTitle != nil) tabTitleLength=\(titleLength) tabIndex=\(tab.index) tabSelected=\(tab.isSelected) bounds=\(bounds.catalogDiagnosticDescription)"
        }
        return "window=\(identity.windowID) pid=\(identity.ownerProcessIdentifier) owner=\(ownerName.catalogDiagnosticValue) title=\(identity.title.catalogDiagnosticValue) bounds=\(bounds.catalogDiagnosticDescription)"
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
    let tabs: [AccessibilityTabSnapshot]
    let tabSource: AccessibilityTabSource?
    let tabSkipReason: String?
    let tabDurationMs: Int

    init(
        title: String?,
        frame: CGRect,
        tabs: [AccessibilityTabSnapshot] = [],
        tabSource: AccessibilityTabSource? = nil,
        tabSkipReason: String? = nil,
        tabDurationMs: Int = 0
    ) {
        self.title = title?.nonBlankCatalogTitle
        self.frame = frame
        self.tabs = tabs
        self.tabSource = tabSource
        self.tabSkipReason = tabSkipReason
        self.tabDurationMs = tabDurationMs
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

    init?(window: AXUIElement, resolveTabs: Bool = true) {
        guard let frame = CGRect.fromAccessibilityWindow(window) else { return nil }
        let tabResolution = resolveTabs
            ? AccessibilityTabResolver.resolveTabs(in: window)
            : AccessibilityTabResolution(
                tabs: [],
                source: nil,
                skipReason: "tab-resolution-disabled",
                durationMs: 0
            )
        self.title = AccessibilityWindowSnapshot.title(of: window)
        self.frame = frame
        self.tabs = tabResolution.tabs
        self.tabSource = tabResolution.source
        self.tabSkipReason = tabResolution.skipReason
        self.tabDurationMs = tabResolution.durationMs
    }

    static func title(of window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else {
            return nil
        }
        return (rawTitle as? String)?.nonBlankCatalogTitle
    }

    var diagnosticDescription: String {
        "title=\(title.catalogDiagnosticValue) frame=\(frame.catalogDiagnosticDescription) tabs=\(tabs.count) tabSource=\(tabSource?.rawValue ?? "missing") tabSkip=\(tabSkipReason ?? "nil")"
    }
}

private extension CGRect {
    var windowFrameIdentity: WindowFrameIdentity {
        WindowFrameIdentity(
            x: Double(origin.x),
            y: Double(origin.y),
            width: Double(size.width),
            height: Double(size.height)
        )
    }

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
