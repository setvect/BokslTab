import ApplicationServices
import Foundation

/// Reads one app's live AX windows; all matching/composition is done on snapshots.
enum AccessibilityWindowDiscovery {
    /// Handles of numbered windows go to `elementCache`, so the window stays raisable after it
    /// leaves the current Space.
    static func snapshots(
        for pid: Int32,
        resolveTabs: Bool,
        query: AccessibilityQueryBudget,
        elementCache: AccessibilityWindowElementCache? = nil
    ) -> [AccessibilityWindowSnapshot] {
        let app = AXUIElementCreateApplication(pid)
        var windows = query.reader.elements(from: app, attribute: kAXWindowsAttribute)
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            guard query.copyAttributeValue(app, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { continue }
            windows.append(value as! AXUIElement)
        }
        let snapshots = windows.compactMap { window -> AccessibilityWindowSnapshot? in
            guard let snapshot = AccessibilityWindowSnapshot(window: window, resolveTabs: resolveTabs, query: query) else {
                return nil
            }
            if let windowID = snapshot.windowID {
                elementCache?.record(window, windowID: windowID, processIdentifier: pid)
            }
            return snapshot
        }
        return AccessibilityWindowSnapshot.deduplicated(snapshots)
    }
}
