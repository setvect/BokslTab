import AppKit
import ApplicationServices
import BokslTabCore
import Foundation

public final class MacOSAppActivator: AppActivating {
    private let options: NSApplication.ActivationOptions

    public init(options: NSApplication.ActivationOptions = [.activateAllWindows]) {
        self.options = options
    }

    public func activate(app: AppIdentity) -> SwitchResult {
        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            return .safeFailure(reason: "실행 중인 앱을 찾을 수 없습니다: pid=\(app.processIdentifier)")
        }

        let didActivate = runningApp.activate(options: options)
        return didActivate
            ? .appActivationSuccess
            : .safeFailure(reason: "앱 활성화에 실패했습니다: \(app.displayName)")
    }
}

public final class MacOSWindowActivator: WindowActivating {
    private let appActivator: AppActivating

    public init(appActivator: AppActivating = MacOSAppActivator(options: [])) {
        self.appActivator = appActivator
    }

    public func activate(window: WindowIdentity, app: AppIdentity) -> SwitchResult {
        guard AXIsProcessTrusted() else {
            return fallbackToApp(app: app, reason: "손쉬운 사용 권한이 없어 앱 활성화로 대체했습니다.")
        }

        guard let axWindow = findExactlyMatchedAXWindow(matching: window, app: app) else {
            return fallbackToApp(app: app, reason: "대상 창을 정확히 식별하지 못해 앱 활성화로 대체했습니다.")
        }

        _ = appActivator.activate(app: app)
        _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raiseError = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        if raiseError == .success {
            return .exactWindowSuccess
        }
        return fallbackToApp(app: app, reason: "창 올리기 액션이 실패해 앱 활성화로 대체했습니다: \(raiseError.rawValue)")
    }

    private func findExactlyMatchedAXWindow(matching window: WindowIdentity, app: AppIdentity) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        let copyError = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard copyError == .success,
              let windows = rawWindows as? [AXUIElement],
              let targetTitle = window.title?.nonBlankForAdapter
        else { return nil }

        let candidateTitles = windows.map(title(of:))
        guard let matchedIndex = AXWindowMatchPolicy.uniqueTitleMatchIndex(
            targetTitle: targetTitle,
            candidateTitles: candidateTitles
        ) else { return nil }

        return windows[matchedIndex]
    }

    private func title(of window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else {
            return nil
        }
        return rawTitle as? String
    }

    private func fallbackToApp(app: AppIdentity, reason: String) -> SwitchResult {
        switch appActivator.activate(app: app) {
        case .appActivationSuccess, .exactWindowSuccess, .limitedAppFallbackSuccess:
            return .limitedAppFallbackSuccess
        case .safeFailure(let activationReason):
            return .safeFailure(reason: "\(reason) 앱 활성화도 실패했습니다: \(activationReason)")
        }
    }
}

enum AXWindowMatchPolicy {
    static func uniqueTitleMatchIndex(targetTitle: String, candidateTitles: [String?]) -> Int? {
        guard let normalizedTarget = targetTitle.nonBlankForAdapter else { return nil }
        let matches = candidateTitles.enumerated().filter { _, candidate in
            candidate?.nonBlankForAdapter == normalizedTarget
        }
        guard matches.count == 1 else { return nil }
        return matches[0].offset
    }
}

private extension String {
    var nonBlankForAdapter: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
