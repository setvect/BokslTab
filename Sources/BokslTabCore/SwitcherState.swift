import Foundation

public struct SwitcherState: Equatable, Sendable {
    public private(set) var mode: SwitcherMode
    public private(set) var items: [SwitcherItem]
    public private(set) var selectedIndex: Int

    public init(mode: SwitcherMode, items: [SwitcherItem], selectedIndex: Int = 0) {
        self.mode = mode
        self.items = items
        if items.isEmpty {
            self.selectedIndex = 0
        } else {
            self.selectedIndex = max(0, min(selectedIndex, items.count - 1))
        }
    }

    public var selectedItem: SwitcherItem? {
        guard !items.isEmpty, selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    public var isEmpty: Bool { items.isEmpty }

    public mutating func replaceItems(_ newItems: [SwitcherItem]) {
        items = newItems
        selectedIndex = newItems.isEmpty ? 0 : min(selectedIndex, newItems.count - 1)
    }

    public mutating func moveNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    public mutating func movePrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    public mutating func select(index: Int) {
        guard !items.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = max(0, min(index, items.count - 1))
    }
}

public enum SwitcherItemComposer {
    public static func composeAllAppsAndWindows(
        apps: [AppIdentity],
        windows: [WindowIdentity],
        currentProcessIdentifier: Int32? = nil
    ) -> [SwitcherItem] {
        let visibleApps = apps.filter { app in
            if let currentProcessIdentifier, app.processIdentifier == currentProcessIdentifier {
                return false
            }
            return true
        }
        let appsByPID = Dictionary(uniqueKeysWithValues: visibleApps.map { ($0.processIdentifier, $0) })
        var appPIDsWithWindow = Set<Int32>()
        var items: [SwitcherItem] = []

        for window in windows {
            guard let app = appsByPID[window.ownerProcessIdentifier] else { continue }
            appPIDsWithWindow.insert(app.processIdentifier)
            items.append(SwitcherItem(app: app, kind: .window(window)))
        }

        for app in visibleApps where !appPIDsWithWindow.contains(app.processIdentifier) {
            items.append(SwitcherItem(app: app, kind: .app))
        }

        return items.sortedForSwitcher()
    }

    public static func composeActiveAppWindows(app: AppIdentity, windows: [WindowIdentity]) -> [SwitcherItem] {
        if windows.isEmpty {
            return [SwitcherItem(app: app, kind: .app)]
        }
        return windows
            .map { SwitcherItem(app: app, kind: .window($0)) }
            .sortedForSwitcher()
    }
}
