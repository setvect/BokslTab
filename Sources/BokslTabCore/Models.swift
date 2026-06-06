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

public struct WindowIdentity: Hashable, Sendable {
    public let windowID: UInt32
    public let ownerProcessIdentifier: Int32
    public let title: String?

    public init(windowID: UInt32, ownerProcessIdentifier: Int32, title: String? = nil) {
        self.windowID = windowID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.title = title
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
                self.id = "app:\(app.processIdentifier)"
            case .window(let window):
                self.id = "window:\(window.windowID):\(window.ownerProcessIdentifier)"
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
