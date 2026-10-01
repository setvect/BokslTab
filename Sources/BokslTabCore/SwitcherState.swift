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

    /// Keep existing rows in place and preserve the activation target when details arrive.
    /// A selected parent window may become its currently selected native tab; an explicit
    /// tab that disappears is never silently replaced by a different tab.
    @discardableResult
    public mutating func mergeRefreshedItems(_ newItems: [SwitcherItem]) -> Bool {
        let selectedID: String?
        if let selected = selectedItem {
            if case .window(let window) = selected.kind, let tab = window.tab {
                let matches = newItems.filter { item in
                    guard case .window(let candidate) = item.kind, let candidateTab = candidate.tab else { return false }
                    return candidate.ownerProcessIdentifier == window.ownerProcessIdentifier
                        && candidateTab.parentWindowID == tab.parentWindowID
                        && candidateTab.title == tab.title
                }
                if let exact = matches.first(where: { $0.id == selected.id }) {
                    selectedID = exact.id
                } else if matches.count == 1 {
                    selectedID = matches[0].id
                } else {
                    return false
                }
            } else if newItems.contains(where: { $0.id == selected.id }) {
                selectedID = selected.id
            } else if case .app = selected.kind,
                      let firstWindow = newItems.first(where: {
                          $0.app.processIdentifier == selected.app.processIdentifier && $0.isWindow
                      }) {
                selectedID = firstWindow.id
            } else if case .window(let window) = selected.kind, window.tab == nil,
                      let selectedTab = newItems.first(where: { item in
                          guard case .window(let candidate) = item.kind else { return false }
                          return candidate.ownerProcessIdentifier == window.ownerProcessIdentifier
                              && candidate.tab?.parentWindowID == window.windowID
                              && candidate.tab?.isSelected == true
                      }) {
                selectedID = selectedTab.id
            } else {
                return false
            }
        } else {
            selectedID = newItems.first?.id
        }

        var merged: [SwitcherItem] = []
        var includedIDs = Set<String>()
        for previous in items {
            let replacements: [SwitcherItem]
            if let exact = newItems.first(where: { $0.id == previous.id }) {
                replacements = [exact]
            } else if case .window(let window) = previous.kind, window.tab == nil {
                replacements = newItems.filter { item in
                    guard case .window(let candidate) = item.kind else { return false }
                    return candidate.ownerProcessIdentifier == window.ownerProcessIdentifier
                        && candidate.tab?.parentWindowID == window.windowID
                }
            } else {
                replacements = []
            }
            for item in replacements where includedIDs.insert(item.id).inserted {
                merged.append(item)
            }
        }
        for item in newItems where includedIDs.insert(item.id).inserted {
            merged.append(item)
        }
        guard merged != items else { return false }
        items = merged
        selectedIndex = selectedID.flatMap { id in merged.firstIndex(where: { $0.id == id }) } ?? 0
        return true
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
        var items: [SwitcherItem] = []

        for window in windows {
            guard let app = appsByPID[window.ownerProcessIdentifier] else { continue }
            items.append(SwitcherItem(app: app, kind: .window(window)))
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
