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

/// Pairs the tabs of an app's tab bars with the windows known for them.
///
/// Every tab of a native tab group is a window of its own, but AX lists only the selected one and
/// names the others just by their tab titles. A tab belongs to the window already known for it: the
/// group's on-screen window, or a remembered window that is now shown on no Space. Those keep their
/// window rows and numbers. Only a tab nobody claims becomes a tab row, reached by pressing it.
final class NativeTabMatcher {
    struct Tab: Equatable {
        let index: Int
        let title: String

        var key: String { StableWindowTitleKey.normalized(title) }
    }

    struct Group {
        /// The group's window that is on screen now; unclaimed tabs are pressed in it.
        let parent: WindowSnapshot
        let tabBarFrame: CGRect
        var unclaimedTabs: [Tab]
    }

    private var groups: [Group]

    init(groups: [Group] = []) {
        self.groups = groups
    }

    /// Whether a window of the app that is shown on no Space is one of its unselected tabs. The tab it
    /// matches is taken, so a second window with the same name needs a second tab of that name.
    func claimTab(processIdentifier: Int32, keys: Set<String>) -> Bool {
        for groupIndex in groups.indices
        where groups[groupIndex].parent.identity.ownerProcessIdentifier == processIdentifier {
            guard let tabIndex = groups[groupIndex].unclaimedTabs.firstIndex(where: { keys.contains($0.key) }) else {
                continue
            }
            groups[groupIndex].unclaimedTabs.remove(at: tabIndex)
            return true
        }
        return false
    }

    /// Tabs whose windows have not been seen yet. Call after every known window has claimed its tab.
    func unclaimedTabSnapshots() -> [WindowSnapshot] {
        groups.flatMap { group in
            group.unclaimedTabs.map { tab in
                WindowSnapshot(
                    identity: WindowIdentity(
                        windowID: group.parent.identity.windowID,
                        ownerProcessIdentifier: group.parent.identity.ownerProcessIdentifier,
                        title: tab.title,
                        tab: WindowTabIdentity(
                            parentWindowID: group.parent.identity.windowID,
                            parentTitle: group.parent.identity.title?.nonBlankCatalogTitle,
                            parentFrame: group.tabBarFrame.windowFrameIdentity,
                            index: tab.index,
                            title: tab.title,
                            isSelected: false
                        ),
                        source: group.parent.identity.source
                    ),
                    bounds: group.parent.bounds,
                    ownerName: group.parent.ownerName
                )
            }
        }
    }
}

extension NativeTabMatcher.Group {
    /// The tab bar as AX last read it. The details may predate a tab switch: then the window they
    /// describe is an unselected tab now, and the on-screen window in its place is the group's parent.
    /// Returns nil when the bar holds a single tab or no window of the group is on screen.
    init?(
        tabBar: AccessibilityWindowSnapshot,
        onScreenRows: [WindowSnapshot],
        rememberedKeysByWindowID: [UInt32: Set<String>],
        isOrderedOut: (UInt32) -> Bool
    ) {
        guard tabBar.tabs.count > 1 else { return nil }
        var tabs = tabBar.tabs.compactMap { tab in
            TabTitlePolicy.usableTitle(tab.title).map { (tab: NativeTabMatcher.Tab(index: tab.index, title: $0), isSelected: tab.isSelected) }
        }

        func siblingOnScreen() -> WindowSnapshot? {
            WindowFrameMatchPolicy.bestFrameMatchIndex(
                targetFrame: tabBar.frame,
                candidateFrames: onScreenRows.map(\.bounds)
            ).map { onScreenRows[$0] }
        }
        func claimByTitle(_ row: WindowSnapshot) {
            var keys = rememberedKeysByWindowID[row.identity.windowID] ?? []
            if let title = row.identity.title?.nonBlankCatalogTitle {
                keys.insert(StableWindowTitleKey.normalized(title))
            }
            if let index = tabs.firstIndex(where: { keys.contains($0.tab.key) }) {
                tabs.remove(at: index)
            }
        }

        let own = tabBar.windowID.flatMap { windowID in onScreenRows.first { $0.identity.windowID == windowID } }
            ?? (tabBar.windowID == nil ? siblingOnScreen() : nil)
        if let own {
            // The selected tab is this window itself, whatever the two are titled.
            if let index = tabs.firstIndex(where: \.isSelected) {
                tabs.remove(at: index)
            } else {
                claimByTitle(own)
            }
            self.parent = own
        } else if let windowID = tabBar.windowID, isOrderedOut(windowID), let sibling = siblingOnScreen() {
            claimByTitle(sibling)
            self.parent = sibling
        } else {
            return nil
        }
        self.tabBarFrame = tabBar.frame
        self.unclaimedTabs = tabs.map(\.tab)
    }
}

struct TabTitlePolicy {
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
