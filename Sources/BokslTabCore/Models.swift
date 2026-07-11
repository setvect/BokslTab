import Foundation

public struct AppIdentity: Hashable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let processName: String?

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        processName: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processName = processName
    }

    public var displayName: String {
        localizedName?.nonBlank
            ?? processName?.nonBlank
            ?? bundleIdentifier?.nonBlank
            ?? "Unknown App"
    }
}

public struct WindowTabIdentity: Hashable, Sendable {
    public let parentWindowID: UInt32
    public let parentTitle: String?
    public let parentFrame: WindowFrameIdentity?
    public let index: Int
    public let title: String
    public let isSelected: Bool

    public init(
        parentWindowID: UInt32,
        parentTitle: String? = nil,
        parentFrame: WindowFrameIdentity? = nil,
        index: Int,
        title: String,
        isSelected: Bool = false
    ) {
        self.parentWindowID = parentWindowID
        self.parentTitle = parentTitle
        self.parentFrame = parentFrame
        self.index = index
        self.title = title
        self.isSelected = isSelected
    }

    public static func == (lhs: WindowTabIdentity, rhs: WindowTabIdentity) -> Bool {
        lhs.parentWindowID == rhs.parentWindowID
            && lhs.parentTitle == rhs.parentTitle
            && lhs.index == rhs.index
            && lhs.title == rhs.title
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(parentWindowID)
        hasher.combine(parentTitle)
        hasher.combine(index)
        hasher.combine(title)
    }
}

public struct WindowFrameIdentity: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum WindowIdentitySource: String, Hashable, Sendable {
    case coreGraphics
    case accessibilityOnly
    case accessibilityEvent
    case cached
}

public struct WindowIdentity: Hashable, Sendable {
    public let windowID: UInt32
    public let ownerProcessIdentifier: Int32
    public let title: String?
    public let tab: WindowTabIdentity?
    public let source: WindowIdentitySource

    public init(
        windowID: UInt32,
        ownerProcessIdentifier: Int32,
        title: String? = nil,
        tab: WindowTabIdentity? = nil,
        source: WindowIdentitySource = .coreGraphics
    ) {
        self.windowID = windowID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.title = title
        self.tab = tab
        self.source = source
    }
}

public enum SwitcherMode: String, CaseIterable, Sendable {
    case allAppsAndWindows
    case activeAppWindows
}

public enum SwitcherItemKind: Hashable, Sendable {
    case app
    case window(WindowIdentity)
}

public struct SwitcherItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let app: AppIdentity
    public let kind: SwitcherItemKind

    public init(id: String? = nil, app: AppIdentity, kind: SwitcherItemKind) {
        self.app = app
        self.kind = kind
        if let id {
            self.id = id
        } else {
            switch kind {
            case .app:
                self.id = SwitcherItem.appID(processIdentifier: app.processIdentifier)
            case .window(let window):
                if let tab = window.tab {
                    self.id = SwitcherItem.tabWindowID(
                        parentWindowID: tab.parentWindowID,
                        ownerProcessIdentifier: window.ownerProcessIdentifier,
                        index: tab.index
                    )
                } else {
                    self.id = SwitcherItem.windowID(
                        windowID: window.windowID,
                        ownerProcessIdentifier: window.ownerProcessIdentifier
                    )
                }
            }
        }
    }

    public var title: String {
        switch kind {
        case .app:
            return app.displayName
        case .window(let window):
            if let title = window.title?.nonBlank {
                return title
            }
            return "\(app.displayName) 창 \(window.windowID)"
        }
    }

    public var subtitle: String? {
        switch kind {
        case .app:
            return nil
        case .window:
            return app.displayName == title ? nil : app.displayName
        }
    }

    public var isWindow: Bool {
        if case .window = kind { return true }
        return false
    }

    public var mruProjectedIDs: [String] {
        switch kind {
        case .app:
            return [id]
        case .window(let window):
            var projectedIDs = [id]
            if (window.source == .accessibilityEvent || window.tab != nil),
               let title = window.title,
               let stableTitleID = SwitcherItem.stableTitleAliasID(
                   ownerProcessIdentifier: window.ownerProcessIdentifier,
                   title: title
               ) {
                projectedIDs.append(stableTitleID)
            }

            if let tab = window.tab {
                projectedIDs.append(
                    SwitcherItem.windowID(
                        windowID: tab.parentWindowID,
                        ownerProcessIdentifier: window.ownerProcessIdentifier
                    )
                )
            }
            projectedIDs.append(SwitcherItem.appID(processIdentifier: app.processIdentifier))
            return projectedIDs
        }
    }


    public static func stableTitleAliasID(ownerProcessIdentifier: Int32, title: String) -> String? {
        guard let stableTitle = StableWindowTitleKey.normalized(title).nonBlank else { return nil }
        return "stable-title:\(ownerProcessIdentifier):\(stableTitle)"
    }

    public static func isStableTitleAliasID(_ id: String) -> Bool {
        id.hasPrefix("stable-title:")
    }

    public static func appID(processIdentifier: Int32) -> String {
        "app:\(processIdentifier)"
    }

    public static func windowID(windowID: UInt32, ownerProcessIdentifier: Int32) -> String {
        "window:\(windowID):\(ownerProcessIdentifier)"
    }

    public static func tabWindowID(
        parentWindowID: UInt32,
        ownerProcessIdentifier: Int32,
        index: Int
    ) -> String {
        "tab:\(parentWindowID):\(ownerProcessIdentifier):\(index)"
    }
}

public enum SwitchResult: Equatable, Sendable {
    case exactWindowSuccess
    case limitedAppFallbackSuccess
    case appActivationSuccess
    case safeFailure(reason: String)
}

public enum PermissionState: Equatable, Sendable {
    case allowed
    case denied(reason: String)
    case unknown
}

public extension Array where Element == SwitcherItem {
    func sortedForSwitcher() -> [SwitcherItem] {
        sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
