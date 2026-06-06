import ApplicationServices
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSWindowCatalogProvider: WindowCatalogProviding {
    public init() {}

    public func windowsForAllApps() -> [WindowIdentity] {
        currentOnScreenWindows()
    }

    public func windows(for app: AppIdentity) -> [WindowIdentity] {
        currentOnScreenWindows().filter { $0.ownerProcessIdentifier == app.processIdentifier }
    }

    private func currentOnScreenWindows() -> [WindowIdentity] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let snapshots = infoList.compactMap(WindowSnapshot.init(windowInfo:))
        return enrichTitlesFromAccessibilityIfPossible(snapshots).map(\.identity)
    }

    private func enrichTitlesFromAccessibilityIfPossible(_ snapshots: [WindowSnapshot]) -> [WindowSnapshot] {
        guard AXIsProcessTrusted() else { return snapshots }

        let axSnapshotsByPID = accessibilityWindowSnapshotsByPID(
            Set(snapshots.map { $0.identity.ownerProcessIdentifier })
        )
        guard !axSnapshotsByPID.isEmpty else { return snapshots }

        var enrichedSnapshots = snapshots

        for processIdentifier in Set(snapshots.map({ $0.identity.ownerProcessIdentifier })) {
            guard let axSnapshots = axSnapshotsByPID[processIdentifier], !axSnapshots.isEmpty else { continue }

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
                        accessibilityTitle: axSnapshots[axIndex].title
                    )
                )
            }

            let untitledSnapshotIndices = snapshotIndices.filter {
                enrichedSnapshots[$0].identity.title?.nonBlankCatalogTitle == nil
            }
            let availableTitles = axSnapshots.indices
                .filter { !usedAXIndices.contains($0) }
                .compactMap { axSnapshots[$0].title }
            let fallbackAssignments = AXTitleFallbackPolicy.assignUniqueTitles(
                untitledWindowIDs: untitledSnapshotIndices.map { enrichedSnapshots[$0].identity.windowID },
                availableTitles: availableTitles
            )

            for snapshotIndex in untitledSnapshotIndices {
                let windowID = enrichedSnapshots[snapshotIndex].identity.windowID
                if let title = fallbackAssignments[windowID] {
                    enrichedSnapshots[snapshotIndex] = enrichedSnapshots[snapshotIndex].withTitle(title)
                }
            }
        }

        return enrichedSnapshots
    }

    private func accessibilityWindowSnapshotsByPID(_ processIdentifiers: Set<Int32>) -> [Int32: [AccessibilityWindowSnapshot]] {
        var snapshotsByPID: [Int32: [AccessibilityWindowSnapshot]] = [:]

        for processIdentifier in processIdentifiers {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows) == .success,
                  let axWindows = rawWindows as? [AXUIElement]
            else { continue }

            let snapshots = axWindows.compactMap(AccessibilityWindowSnapshot.init(window:))
            if !snapshots.isEmpty {
                snapshotsByPID[processIdentifier] = snapshots
            }
        }

        return snapshotsByPID
    }

    private func bestAccessibilityMatchIndex(
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

        // If both APIs report exactly one remaining window for a process, matching is still unambiguous.
        return candidateIndices.count == 1 ? candidateIndices[0] : nil
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
    static func assignUniqueTitles(untitledWindowIDs: [UInt32], availableTitles: [String]) -> [UInt32: String] {
        let normalizedTitles = availableTitles.compactMap(\.nonBlankCatalogTitle)
        guard !untitledWindowIDs.isEmpty,
              untitledWindowIDs.count == normalizedTitles.count,
              Set(normalizedTitles).count == normalizedTitles.count
        else { return [:] }

        let sortedWindowIDs = untitledWindowIDs.sorted()
        let sortedTitles = normalizedTitles.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: zip(sortedWindowIDs, sortedTitles))
    }
}

struct WindowTitleSelectionPolicy {
    static func bestTitle(coreGraphicsTitle: String?, accessibilityTitle: String?) -> String? {
        guard let axTitle = accessibilityTitle?.nonBlankCatalogTitle else {
            return coreGraphicsTitle?.nonBlankCatalogTitle
        }
        guard let cgTitle = coreGraphicsTitle?.nonBlankCatalogTitle else {
            return axTitle
        }
        guard axTitle != cgTitle else { return cgTitle }

        // AX titles often include document/page context while CG can be truncated or generic.
        return axTitle.count > cgTitle.count ? axTitle : cgTitle
    }
}

private struct WindowSnapshot {
    let identity: WindowIdentity
    let bounds: CGRect

    init(identity: WindowIdentity, bounds: CGRect) {
        self.identity = identity
        self.bounds = bounds
    }

    init?(windowInfo: [String: Any]) {
        guard let layerNumber = windowInfo[kCGWindowLayer as String] as? NSNumber,
              layerNumber.intValue == 0,
              let pidNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
              let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber,
              let bounds = CGRect.fromWindowInfo(windowInfo[kCGWindowBounds as String]),
              WindowSnapshot.isReasonableWindowBounds(bounds)
        else { return nil }

        let title = (windowInfo[kCGWindowName as String] as? String)?.nonBlankCatalogTitle
        self.init(
            identity: WindowIdentity(
                windowID: windowNumber.uint32Value,
                ownerProcessIdentifier: pidNumber.int32Value,
                title: title
            ),
            bounds: bounds
        )
    }

    func withTitle(_ title: String?) -> WindowSnapshot {
        WindowSnapshot(
            identity: WindowIdentity(
                windowID: identity.windowID,
                ownerProcessIdentifier: identity.ownerProcessIdentifier,
                title: title
            ),
            bounds: bounds
        )
    }

    static func isReasonableWindowBounds(_ bounds: CGRect) -> Bool {
        bounds.width >= 40 && bounds.height >= 40
    }
}

private struct AccessibilityWindowSnapshot {
    let title: String?
    let frame: CGRect

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
}
