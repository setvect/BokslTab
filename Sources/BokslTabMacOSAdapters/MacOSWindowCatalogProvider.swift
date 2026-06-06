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

        return infoList.compactMap(WindowIdentity.init(windowInfo:))
    }
}

private extension WindowIdentity {
    init?(windowInfo: [String: Any]) {
        guard let layerNumber = windowInfo[kCGWindowLayer as String] as? NSNumber,
              layerNumber.intValue == 0,
              let pidNumber = windowInfo[kCGWindowOwnerPID as String] as? NSNumber,
              let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber,
              WindowIdentity.isReasonableWindowBounds(windowInfo[kCGWindowBounds as String])
        else { return nil }

        let title = (windowInfo[kCGWindowName as String] as? String)?.nonBlankForAdapter
        self.init(
            windowID: windowNumber.uint32Value,
            ownerProcessIdentifier: pidNumber.int32Value,
            title: title
        )
    }

    static func isReasonableWindowBounds(_ rawBounds: Any?) -> Bool {
        guard let dictionary = rawBounds as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        else { return true }
        return bounds.width >= 40 && bounds.height >= 40
    }
}

private extension String {
    var nonBlankForAdapter: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
