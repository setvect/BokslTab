import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

enum SyntheticWindowID {
    static func accessibilityEvent(
        processIdentifier: Int32,
        title: String,
        frame: CGRect,
        index: Int
    ) -> UInt32 {
        0x2000_0000 | (hash(
            processIdentifier: processIdentifier,
            title: StableWindowTitleKey.normalized(title),
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
                tab: identity.tab,
                source: identity.source
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

    init?(window: AXUIElement, resolveTabs: Bool = true, query: AccessibilityQueryBudget) {
        guard let frame = query.reader.frame(of: window) else { return nil }
        let tabResolution = resolveTabs
            ? AccessibilityTabResolver.resolveTabs(in: window, query: query)
            : AccessibilityTabResolution(
                tabs: [],
                source: nil,
                skipReason: "tab-resolution-disabled",
                durationMs: 0
            )
        self.title = AccessibilityWindowSnapshot.title(of: window, query: query)
        self.frame = frame
        self.tabs = tabResolution.tabs
        self.tabSource = tabResolution.source
        self.tabSkipReason = tabResolution.skipReason
        self.tabDurationMs = tabResolution.durationMs
    }

    static func title(of window: AXUIElement, query: AccessibilityQueryBudget) -> String? {
        var rawTitle: CFTypeRef?
        guard query.copyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else {
            return nil
        }
        return (rawTitle as? String)?.nonBlankCatalogTitle
    }

    var diagnosticDescription: String {
        "title=\(title.catalogDiagnosticValue) frame=\(frame.catalogDiagnosticDescription) tabs=\(tabs.count) tabSource=\(tabSource?.rawValue ?? "missing") tabSkip=\(tabSkipReason ?? "nil")"
    }
}

extension CGRect {
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

extension String {
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

extension Optional where Wrapped == String {
    var catalogDiagnosticValue: String {
        guard let self, let nonBlank = self.nonBlankCatalogTitle else { return "nil" }
        return nonBlank.catalogDiagnosticValue
    }
}
