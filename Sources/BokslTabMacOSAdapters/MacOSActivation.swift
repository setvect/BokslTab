import AppKit
import ApplicationServices
import BokslTabCore
import Foundation

public final class MacOSAppActivator: AppActivating {
    private let options: NSApplication.ActivationOptions
    private let workspace: NSWorkspace

    public init(
        options: NSApplication.ActivationOptions = [.activateAllWindows],
        workspace: NSWorkspace = .shared
    ) {
        self.options = options
        self.workspace = workspace
    }

    public func activate(app: AppIdentity, intent: AppActivationIntent) -> SwitchResult {
        switch intent {
        case .focusOnly:
            return focus(app: app)
        case .reopenIfNeeded:
            return reopen(app: app)
        }
    }

    private func focus(app: AppIdentity) -> SwitchResult {
        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            return .safeFailure(reason: "실행 중인 앱을 찾을 수 없습니다: pid=\(app.processIdentifier)")
        }

        let didActivate = runningApp.activate(options: options)
        return didActivate
            ? .appActivationSuccess
            : .safeFailure(reason: "앱 활성화에 실패했습니다: \(app.displayName)")
    }
    private func reopen(app: AppIdentity) -> SwitchResult {
        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            return .safeFailure(reason: "실행 중인 앱을 찾을 수 없습니다: pid=\(app.processIdentifier)")
        }

        let didActivate = runningApp.activate(options: options)
        guard let bundleURL = bundleURL(for: app, runningApp: runningApp) else {
            BokslTabDiagnosticLog.write(
                "app-activation.reopen skipped reason=bundle-url-missing pid=\(app.processIdentifier) activated=\(didActivate)"
            )
            return didActivate
                ? .appActivationSuccess
                : .safeFailure(reason: "앱 번들 경로를 찾지 못해 다시 열 수 없습니다: \(app.displayName)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: bundleURL, configuration: configuration) { reopenedApp, error in
            if let error {
                BokslTabDiagnosticLog.write(
                    "app-activation.reopen completed result=failed pid=\(app.processIdentifier) error=\(error.localizedDescription)"
                )
                return
            }
            BokslTabDiagnosticLog.write(
                "app-activation.reopen completed result=success requestedPID=\(app.processIdentifier) reopenedPID=\(reopenedApp?.processIdentifier ?? -1)"
            )
        }
        BokslTabDiagnosticLog.write(
            "app-activation.reopen requested pid=\(app.processIdentifier) activated=\(didActivate) bundle=\(bundleURL.path)"
        )
        return .appActivationSuccess
    }

    private func bundleURL(for app: AppIdentity, runningApp: NSRunningApplication) -> URL? {
        if let bundleURL = runningApp.bundleURL {
            return bundleURL
        }
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        return workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

public final class MacOSWindowActivator: WindowActivating {
    private let appActivator: AppActivating
    private let isAccessibilityTrusted: () -> Bool

    public init(
        appActivator: AppActivating = MacOSAppActivator(options: []),
        isAccessibilityTrusted: @escaping () -> Bool = AXIsProcessTrusted
    ) {
        self.appActivator = appActivator
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    public func activate(window: WindowIdentity, app: AppIdentity) -> SwitchResult {
        guard isAccessibilityTrusted() else {
            return fallbackToApp(app: app, intent: .focusOnly, reason: "손쉬운 사용 권한이 없어 앱 활성화로 대체했습니다.")
        }

        if window.tab != nil {
            return activateTab(window: window, app: app)
        }

        guard let axWindow = findExactlyMatchedAXWindow(matching: window, app: app)
            ?? findCachedAXWindow(matching: window, app: app)
        else {
            return fallbackToApp(
                app: app,
                intent: fallbackIntent(for: window),
                reason: "대상 창을 정확히 식별하지 못해 앱 활성화로 대체했습니다."
            )
        }

        _ = appActivator.activate(app: app)
        let raiseError = focusAndRaise(axWindow)

        if raiseError == .success {
            return .exactWindowSuccess
        }
        return fallbackToApp(app: app, intent: .focusOnly, reason: "창 올리기 액션이 실패해 앱 활성화로 대체했습니다: \(raiseError.rawValue)")
    }

    private func activateTab(window: WindowIdentity, app: AppIdentity) -> SwitchResult {
        guard let targetTab = window.tab else {
            return fallbackToApp(app: app, intent: .focusOnly, reason: "탭 메타데이터가 없어 앱 활성화로 대체했습니다.")
        }

        BokslTabDiagnosticLog.write(
            "window-activation.ax.tab.start pid=\(app.processIdentifier) parentWindow=\(targetTab.parentWindowID) index=\(targetTab.index) titleLength=\(targetTab.title.count) parentTitleKnown=\(targetTab.parentTitle?.nonBlankForAdapter != nil) parentFrameKnown=\(targetTab.parentFrame != nil)"
        )

        guard let match = findAXWindowAndTab(matching: window, app: app) else {
            BokslTabDiagnosticLog.write(
                "window-activation.ax.tab.match result=missing pid=\(app.processIdentifier) parentWindow=\(targetTab.parentWindowID) index=\(targetTab.index)"
            )
            return fallbackToApp(app: app, intent: .focusOnly, reason: "대상 탭을 식별하지 못해 앱 활성화로 대체했습니다.")
        }

        BokslTabDiagnosticLog.write(
            "window-activation.ax.tab.match result=\(match.matchDescription) pid=\(app.processIdentifier) parentWindow=\(targetTab.parentWindowID) index=\(targetTab.index)"
        )

        let activationPlan = AXTabActivationPlan.resolve(
            parentIsMain: AXElementReader.bool(from: match.window, attribute: kAXMainAttribute)
        )
        BokslTabDiagnosticLog.write(
            "window-activation.ax.tab.parent-focus plan=\(activationPlan.logDescription)"
        )

        _ = appActivator.activate(app: app)
        let preselectionRaiseError: AXError?
        switch activationPlan {
        case .selectOnly:
            preselectionRaiseError = nil
        case .focusParentThenSelect:
            preselectionRaiseError = focusAndRaise(match.window)
            BokslTabDiagnosticLog.write(
                "window-activation.ax.tab.parent-focus action=focus-raise result=\(preselectionRaiseError?.rawValue ?? AXError.failure.rawValue)"
            )
        }

        let selection = select(tab: match.tab.element)
        BokslTabDiagnosticLog.write(
            "window-activation.ax.tab.select method=\(selection.method) result=\(selection.success ? "success" : "failed") error=\(selection.errorCode.map(String.init) ?? "nil")"
        )

        if selection.success {
            guard preselectionRaiseError == nil || preselectionRaiseError == .success else {
                return .limitedAppFallbackSuccess
            }
            BokslTabDiagnosticLog.write(
                "window-activation.ax.tab.refocus skipped=true reason=tab-selection-success"
            )
            return .exactWindowSuccess
        }

        let raiseError = preselectionRaiseError ?? focusAndRaise(match.window)
        if raiseError == .success {
            return .limitedAppFallbackSuccess
        }
        return fallbackToApp(
            app: app,
            intent: .focusOnly,
            reason: "탭 선택 또는 창 올리기 액션이 실패해 앱 활성화로 대체했습니다: select=false, raise=\(raiseError.rawValue)"
        )
    }

    private func findAXWindowAndTab(
        matching window: WindowIdentity,
        app: AppIdentity
    ) -> AXWindowTabMatch? {
        guard let targetTab = window.tab else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axWindows(from: appElement), !windows.isEmpty else { return nil }
        let parentCandidates = parentCandidateWindows(for: targetTab, windows: windows)
        BokslTabDiagnosticLog.write(
            "window-activation.ax.tab.parent strategy=\(parentCandidates.strategy) candidates=\(parentCandidates.windows.count) pid=\(app.processIdentifier) parentWindow=\(targetTab.parentWindowID)"
        )

        let matches = parentCandidates.windows.compactMap { candidateWindow -> AXWindowTabMatch? in
            let tabs = AXTabElementSnapshot.tabs(in: candidateWindow)
            guard let tabIndex = AXTabMatchPolicy.bestMatchIndex(target: targetTab, candidates: tabs) else {
                return nil
            }
            return AXWindowTabMatch(
                window: candidateWindow,
                tab: tabs[tabIndex],
                matchDescription: AXTabMatchPolicy.matchDescription(target: targetTab, candidates: tabs, index: tabIndex)
            )
        }

        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func parentCandidateWindows(
        for targetTab: WindowTabIdentity,
        windows: [AXUIElement]
    ) -> AXParentWindowCandidateResolution<AXUIElement> {
        let resolution = AXParentWindowMatchPolicy.candidateIndices(
            target: targetTab,
            candidateTitles: windows.map(title(of:)),
            candidateFrames: windows.map(frame(of:))
        )
        return AXParentWindowCandidateResolution(
            windows: resolution.indices.map { windows[$0] },
            strategy: resolution.strategy
        )
    }

    private func findExactlyMatchedAXWindow(matching window: WindowIdentity, app: AppIdentity) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axWindows(from: appElement),
              let targetTitle = window.title?.nonBlankForAdapter
        else { return nil }

        let candidateTitles = windows.map(title(of:))
        guard let matchedIndex = AXWindowMatchPolicy.uniqueTitleMatchIndex(
            targetTitle: targetTitle,
            candidateTitles: candidateTitles
        ) else { return nil }

        return windows[matchedIndex]
    }

    private func findCachedAXWindow(matching window: WindowIdentity, app: AppIdentity) -> AXUIElement? {
        guard let cachedWindow = AccessibilityWindowEventCache.shared.window(matching: window, app: app) else {
            BokslTabDiagnosticLog.write(
                "window-activation.ax.event-cache.match result=missing pid=\(app.processIdentifier) window=\(window.windowID) titleKnown=\(window.title?.nonBlankForAdapter != nil)"
            )
            return nil
        }
        BokslTabDiagnosticLog.write(
            "window-activation.ax.event-cache.match result=hit pid=\(app.processIdentifier) window=\(window.windowID) titleKnown=\(window.title?.nonBlankForAdapter != nil)"
        )
        return cachedWindow
    }

    private func axWindows(from appElement: AXUIElement) -> [AXUIElement]? {
        var rawWindows: CFTypeRef?
        let copyError = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard copyError == .success else { return nil }
        return rawWindows as? [AXUIElement]
    }

    private func select(tab: AXUIElement) -> AXTabSelectionResult {
        let pressError = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        if pressError == .success {
            return AXTabSelectionResult(success: true, method: "press", errorCode: nil)
        }

        let selectedError = AXUIElementSetAttributeValue(tab, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if selectedError == .success {
            return AXTabSelectionResult(success: true, method: "selected-attribute", errorCode: nil)
        }

        return AXTabSelectionResult(success: false, method: "fallback", errorCode: selectedError.rawValue)
    }

    private func focusAndRaise(_ axWindow: AXUIElement) -> AXError {
        _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    private func title(of window: AXUIElement) -> String? {
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else {
            return nil
        }
        return rawTitle as? String
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        AXElementReader.frame(of: window)
    }

    private func fallbackIntent(for window: WindowIdentity) -> AppActivationIntent {
        window.source == .cached ? .reopenIfNeeded : .focusOnly
    }

    private func fallbackToApp(
        app: AppIdentity,
        intent: AppActivationIntent,
        reason: String
    ) -> SwitchResult {
        BokslTabDiagnosticLog.write(
            "window-activation.fallback intent=\(intent) pid=\(app.processIdentifier) reason=\(reason)"
        )
        let activationResult = appActivator.activate(app: app, intent: intent)

        switch activationResult {
        case .appActivationSuccess, .exactWindowSuccess, .limitedAppFallbackSuccess:
            return .limitedAppFallbackSuccess
        case .safeFailure(let activationReason):
            return .safeFailure(reason: "\(reason) 앱 활성화도 실패했습니다: \(activationReason)")
        }
    }
}

enum AXTabActivationPlan: Equatable {
    case selectOnly
    case focusParentThenSelect

    static func resolve(parentIsMain: Bool) -> AXTabActivationPlan {
        parentIsMain ? .selectOnly : .focusParentThenSelect
    }

    var logDescription: String {
        switch self {
        case .selectOnly:
            return "select-only"
        case .focusParentThenSelect:
            return "focus-parent-then-select"
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

struct AXParentWindowCandidateIndexResolution {
    let indices: [Int]
    let strategy: String
}

struct AXParentWindowCandidateResolution<Window> {
    let windows: [Window]
    let strategy: String
}

enum AXParentWindowMatchPolicy {
    static func candidateIndices(
        target: WindowTabIdentity,
        candidateTitles: [String?],
        candidateFrames: [CGRect?]
    ) -> AXParentWindowCandidateIndexResolution {
        if let targetFrame = target.parentFrame?.cgRect,
           let frameMatchedIndex = uniqueFrameMatchIndex(
               targetFrame: targetFrame,
               candidateFrames: candidateFrames
           ) {
            return AXParentWindowCandidateIndexResolution(indices: [frameMatchedIndex], strategy: "frame")
        }

        if let parentTitle = target.parentTitle?.nonBlankForAdapter,
           let titleMatchedIndex = AXWindowMatchPolicy.uniqueTitleMatchIndex(
               targetTitle: parentTitle,
               candidateTitles: candidateTitles
           ) {
            return AXParentWindowCandidateIndexResolution(indices: [titleMatchedIndex], strategy: "title")
        }

        return AXParentWindowCandidateIndexResolution(indices: Array(candidateTitles.indices), strategy: "all")
    }

    private static func uniqueFrameMatchIndex(targetFrame: CGRect, candidateFrames: [CGRect?]) -> Int? {
        let indexedFrames = candidateFrames.enumerated().compactMap { index, frame -> (index: Int, frame: CGRect)? in
            guard let frame else { return nil }
            return (index, frame)
        }
        guard !indexedFrames.isEmpty else { return nil }

        if let localIndex = WindowFrameMatchPolicy.bestFrameMatchIndex(
            targetFrame: targetFrame,
            candidateFrames: indexedFrames.map(\.frame)
        ) {
            return indexedFrames[localIndex].index
        }

        if let localIndex = WindowFrameMatchPolicy.bestSizeMatchIndex(
            targetFrame: targetFrame,
            candidateFrames: indexedFrames.map(\.frame)
        ) {
            return indexedFrames[localIndex].index
        }

        return nil
    }
}

struct AXTabElementSnapshot {
    let index: Int
    let title: String?
    let isSelected: Bool
    let element: AXUIElement

    static func tabs(in window: AXUIElement) -> [AXTabElementSnapshot] {
        let tabElements = AccessibilityTabResolver.resolveElements(in: window).elements

        return tabElements.enumerated().map { index, element in
            AXTabElementSnapshot(
                index: index,
                title: AccessibilityTabResolver.title(of: element),
                isSelected: AccessibilityTabResolver.isSelected(element),
                element: element
            )
        }
    }
}

struct AXTabMatchPolicy {
    static func bestMatchIndex(target: WindowTabIdentity, candidates: [AXTabElementSnapshot]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.indices.contains(target.index) else { return nil }
        let targetTitle = target.title.nonBlankForAdapter

        if let targetTitle,
           candidates[target.index].title?.nonBlankForAdapter == targetTitle {
            return target.index
        }

        if let targetTitle {
            let titleMatches = candidates.enumerated().filter { _, candidate in
                candidate.title?.nonBlankForAdapter == targetTitle
            }
            if titleMatches.count == 1 {
                return titleMatches[0].offset
            }
        }

        return nil
    }

    static func matchDescription(
        target: WindowTabIdentity,
        candidates: [AXTabElementSnapshot],
        index: Int
    ) -> String {
        let targetTitle = target.title.nonBlankForAdapter
        let candidateTitle = candidates.indices.contains(index)
            ? candidates[index].title?.nonBlankForAdapter
            : nil
        if let targetTitle, candidateTitle == targetTitle, index == target.index {
            return "title-index"
        }
        if let targetTitle, candidateTitle == targetTitle {
            return "unique-title"
        }
        return "title-mismatch"
    }
}

struct AXWindowTabMatch {
    let window: AXUIElement
    let tab: AXTabElementSnapshot
    let matchDescription: String
}

struct AXTabSelectionResult {
    let success: Bool
    let method: String
    let errorCode: Int32?
}

private extension String {
    var nonBlankForAdapter: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension WindowFrameIdentity {
    var cgRect: CGRect {
        CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }
}
