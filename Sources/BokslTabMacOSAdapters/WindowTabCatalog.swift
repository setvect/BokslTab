import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

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
    case windowTabGroup = "window-tab-group"
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

struct AccessibilityTabElementResolution {
    let elements: [AXUIElement]
    let source: AccessibilityTabSource?
    let skipReason: String?
}

enum NativeWindowTabGroupPolicy {
    static func tabElements<Element>(
        windowChildren: [Element],
        children: (Element) -> [Element],
        role: (Element) -> String?,
        subrole: (Element) -> String?
    ) -> [Element] {
        windowChildren
            .filter { role($0) == "AXTabGroup" }
            .map { group in
                children(group).filter {
                    role($0) == "AXRadioButton" && subrole($0) == "AXTabButton"
                }
            }
            .max { $0.count < $1.count }
            ?? []
    }
}

struct AccessibilityTabResolver {
    static func resolveTabs(in window: AXUIElement, query: AccessibilityQueryBudget) -> AccessibilityTabResolution {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let resolution = resolveElements(in: window, query: query)
        return AccessibilityTabResolution(
            tabs: snapshots(from: resolution.elements, source: resolution.source ?? .windowTabs, query: query),
            source: resolution.source,
            skipReason: resolution.skipReason,
            durationMs: elapsedMs(since: startedAt)
        )
    }

    static func resolveElements(in window: AXUIElement, query: AccessibilityQueryBudget) -> AccessibilityTabElementResolution {
        var rawTabs: CFTypeRef?
        let error = query.copyAttributeValue(window, kAXTabsAttribute as CFString, &rawTabs)
        if error == .success,
           let tabElements = rawTabs as? [AXUIElement],
           !tabElements.isEmpty {
            return AccessibilityTabElementResolution(
                elements: tabElements,
                source: .windowTabs,
                skipReason: nil
            )
        }

        let windowTabElements = NativeWindowTabGroupPolicy.tabElements(
            windowChildren: query.reader.elements(from: window, attribute: kAXChildrenAttribute),
            children: { query.reader.elements(from: $0, attribute: kAXChildrenAttribute) },
            role: { query.reader.firstString(from: $0, attributes: [kAXRoleAttribute]) },
            subrole: { query.reader.firstString(from: $0, attributes: [kAXSubroleAttribute]) }
        )
        if !windowTabElements.isEmpty {
            return AccessibilityTabElementResolution(
                elements: windowTabElements,
                source: .windowTabGroup,
                skipReason: nil
            )
        }

        return AccessibilityTabElementResolution(
            elements: [],
            source: error == .success ? .windowTabs : nil,
            skipReason: error == .success
                ? "no-tabs"
                : "direct-axtabs-and-window-tab-group-unavailable"
        )
    }

    private static func snapshots(
        from tabElements: [AXUIElement],
        source: AccessibilityTabSource,
        query: AccessibilityQueryBudget
    ) -> [AccessibilityTabSnapshot] {
        tabElements.enumerated().map { index, element in
            AccessibilityTabSnapshot(
                index: index,
                title: title(of: element, query: query),
                isSelected: isSelected(element, query: query),
                source: source
            )
        }
    }

    static func title(of element: AXUIElement, query: AccessibilityQueryBudget) -> String? {
        query.reader.firstString(
            from: element,
            attributes: [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        )
    }

    static func isSelected(_ element: AXUIElement, query: AccessibilityQueryBudget) -> Bool {
        query.reader.bool(from: element, attribute: kAXSelectedAttribute)
            || query.reader.bool(from: element, attribute: kAXValueAttribute)
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
                    ),
                    source: snapshot.identity.source
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
