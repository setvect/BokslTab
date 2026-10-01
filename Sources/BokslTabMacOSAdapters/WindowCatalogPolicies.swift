import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

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
                        title: title,
                        source: .accessibilityOnly
                    ),
                    bounds: axSnapshot.frame,
                    ownerName: app.displayName
                )
            }
        }
    }
}
