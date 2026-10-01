import ApplicationServices
import Foundation

/// Reads one app's live AX windows; all matching/composition is done on snapshots.
enum AccessibilityWindowDiscovery {
    static func snapshots(for pid: Int32, resolveTabs: Bool, query: AccessibilityQueryBudget) -> [AccessibilityWindowSnapshot] {
        let app = AXUIElementCreateApplication(pid)
        var windows = query.reader.elements(from: app, attribute: kAXWindowsAttribute)
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            guard query.copyAttributeValue(app, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { continue }
            windows.append(value as! AXUIElement)
        }
        return AccessibilityWindowSnapshot.deduplicated(windows.compactMap {
            AccessibilityWindowSnapshot(window: $0, resolveTabs: resolveTabs, query: query)
        })
    }
}
