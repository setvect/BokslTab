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

        return snapshots.map { snapshot in
            guard let axSnapshot = bestAccessibilityMatch(
                for: snapshot,
                candidates: axSnapshotsByPID[snapshot.identity.ownerProcessIdentifier] ?? []
            ) else { return snapshot }

            let title = WindowTitleSelectionPolicy.bestTitle(
                coreGraphicsTitle: snapshot.identity.title,
                accessibilityTitle: axSnapshot.title
            )
            guard title != snapshot.identity.title else { return snapshot }

            return WindowSnapshot(
                identity: WindowIdentity(
                    windowID: snapshot.identity.windowID,
                    ownerProcessIdentifier: snapshot.identity.ownerProcessIdentifier,
                    title: title
                ),
                bounds: snapshot.bounds
            )
        }
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

    private func bestAccessibilityMatch(
        for snapshot: WindowSnapshot,
        candidates: [AccessibilityWindowSnapshot]
    ) -> AccessibilityWindowSnapshot? {
        if let matchedIndex = WindowFrameMatchPolicy.bestMatchIndex(
            targetFrame: snapshot.bounds,
            candidateFrames: candidates.map(\.frame)
        ) {
            return candidates[matchedIndex]
        }

        // If both APIs report exactly one window for a process, matching is still unambiguous.
        return candidates.count == 1 ? candidates[0] : nil
    }
}

struct WindowFrameMatchPolicy {
    static let maximumDistance: CGFloat = 24

    static func bestMatchIndex(targetFrame: CGRect, candidateFrames: [CGRect]) -> Int? {
        let matches = candidateFrames.enumerated()
            .map { index, frame in (index: index, distance: frame.distance(to: targetFrame)) }
            .filter { $0.distance <= maximumDistance }
            .sorted { lhs, rhs in lhs.distance < rhs.distance }

        guard let best = matches.first else { return nil }
        if matches.dropFirst().contains(where: { $0.distance == best.distance }) {
            return nil
        }
        return best.index
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

    func distance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX)
            + abs(minY - other.minY)
            + abs(width - other.width)
            + abs(height - other.height)
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
