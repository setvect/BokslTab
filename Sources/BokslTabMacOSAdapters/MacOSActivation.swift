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
    private let accessibility: MacOSAccessibilityService
    private let windowServer: WindowServerWindowAccess
    private let outcomeDelay: TimeInterval
    /// Counts switches, so a check that fires late can tell that the user has started another one.
    @MainActor private var latestActivation = 0

    public convenience init(
        appActivator: AppActivating = MacOSAppActivator(options: []),
        isAccessibilityTrusted: @escaping () -> Bool = AXIsProcessTrusted,
        accessibility: MacOSAccessibilityService = MacOSAccessibilityService()
    ) {
        self.init(
            appActivator: appActivator,
            isAccessibilityTrusted: isAccessibilityTrusted,
            accessibility: accessibility,
            windowServer: .live
        )
    }

    init(
        appActivator: AppActivating,
        isAccessibilityTrusted: @escaping () -> Bool,
        accessibility: MacOSAccessibilityService,
        windowServer: WindowServerWindowAccess,
        outcomeDelay: TimeInterval = 0.6
    ) {
        self.appActivator = appActivator
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.accessibility = accessibility
        self.windowServer = windowServer
        self.outcomeDelay = outcomeDelay
        _ = accessibility.eventObserver
    }

    private enum Target {
        case window(AXUIElement)
        case tab(AXWindowTabMatch, AXTabActivationPlan)

        var windowHandle: AXUIElement? {
            if case .window(let element) = self { return element }
            return nil
        }
    }

    /// What a late check needs to make the switch once more.
    private struct Repeat {
        let activation: Int
        let handle: AXUIElement?
        /// Whether the window itself must have come on screen. Not for a row the window server cannot
        /// tell about (a tab, a window known only to AX), nor when only the app was brought forward.
        let checksWindow: Bool
    }

    @MainActor
    public func activate(window: WindowIdentity, app: AppIdentity) async -> SwitchResult {
        guard !Task.isCancelled else { return .safeFailure(reason: "창 전환이 취소되었습니다.") }
        latestActivation += 1
        let activation = latestActivation
        guard isAccessibilityTrusted() else {
            return fallbackToApp(window: window, app: app, activation: activation, reason: "손쉬운 사용 권한이 없어 앱 활성화로 대체했습니다.")
        }
        // Tabs switch inside their parent window through AX; the window server only focuses whole windows.
        let placement: WindowServerPlacement = window.tab == nil
            ? windowServer.placement(of: window.windowID, ownedBy: app.processIdentifier)
            : .missing
        let target: Target? = await accessibility.run(for: app.processIdentifier) { query in
            if window.tab != nil {
                guard let match = self.findAXWindowAndTab(matching: window, app: app, query: query) else { return nil }
                let plan = AXTabActivationPlan.resolve(
                    parentIsMain: query.reader.bool(from: match.window, attribute: kAXMainAttribute)
                )
                return .tab(match, plan)
            }
            guard let element = self.findAXWindow(matching: window, app: app, query: query) else { return nil }
            return .window(element)
        }
        guard !Task.isCancelled else { return .safeFailure(reason: "창 전환이 취소되었습니다.") }
        if placement == .offScreen,
           let result = await activateOutsideVisibleSpaces(window: window, app: app, target: target, activation: activation) {
            return result
        }
        guard let target else {
            return fallbackToApp(window: window, app: app, activation: activation, reason: "대상 창 조회가 지연되거나 정확히 식별되지 않아 앱 활성화로 대체했습니다.")
        }

        _ = appActivator.activate(app: app)
        // Actions get more time than discovery, but neither can wait on the UI thread.
        let result: SwitchResult? = await accessibility.run(
            for: app.processIdentifier, duration: 1, requestTimeout: 0.25
        ) { query in
            self.performActivation(target, restoresMinimized: placement != .onScreen, query: query)
        }
        guard !Task.isCancelled else { return .safeFailure(reason: "창 전환이 취소되었습니다.") }
        if result != nil {
            logOutcome(
                of: window, app: app, after: window.tab == nil ? "accessibility" : "tab",
                repeatable: Repeat(
                    activation: activation, handle: target.windowHandle, checksWindow: placement != .missing
                )
            )
        }
        if let tab = window.tab, result == .exactWindowSuccess {
            // The window this tab brings on screen has not been seen; the catalog names it by this title.
            accessibility.knownWindows.expectWindow(
                forTabTitled: tab.title,
                processIdentifier: app.processIdentifier,
                now: ProcessInfo.processInfo.systemUptime
            )
        }
        return result ?? fallbackToApp(window: window, app: app, activation: activation, reason: "창 활성화가 지연되어 앱 활성화로 대체했습니다.")
    }

    /// AX cannot list a window on another desktop or in a full-screen Space, but the window server can
    /// focus it. macOS reliably follows to that Space only when the owning app raises the window itself,
    /// so the handle remembered from when the window was visible is raised right after (AltTab's order).
    /// Returns nil to fall back when the window server refuses.
    @MainActor
    private func activateOutsideVisibleSpaces(
        window: WindowIdentity,
        app: AppIdentity,
        target: Target?,
        activation: Int
    ) async -> SwitchResult? {
        let focus = windowServer.focus(window.windowID, app.processIdentifier)
        guard focus == .focused else {
            BokslTabDiagnosticLog.write(
                "window-activation.window-server failed pid=\(app.processIdentifier) window=\(window.windowID) result=\(focus)"
            )
            return nil
        }
        var raise = "no-handle"
        if case .window(let element) = target {
            let raised: Bool? = await accessibility.run(
                for: app.processIdentifier, duration: 1, requestTimeout: 0.25
            ) { query in
                _ = query.setAttribute(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                return self.focusAndRaise(element, query: query) == .success
            }
            raise = raised == true ? "raised" : "failed"
        }
        BokslTabDiagnosticLog.write(
            "window-activation.target by=window-server pid=\(app.processIdentifier) window=\(window.windowID) axRaise=\(raise)"
        )
        guard !Task.isCancelled else { return .safeFailure(reason: "창 전환이 취소되었습니다.") }
        logOutcome(
            of: window, app: app, after: "window-server",
            repeatable: Repeat(activation: activation, handle: target?.windowHandle, checksWindow: true)
        )
        return .exactWindowSuccess
    }

    /// A request can succeed while something else ends up in front: macOS may not follow to the
    /// window's Space, a raised tab may not become the selected one, or another app may take the focus
    /// back. What is really in front is logged for every switch once animations have settled:
    /// the frontmost app, the topmost window, and where the target sits in the stacking (0 is the top).
    ///
    /// When the switch visibly did not hold, it is made once more (`repeatable`). Claude's window was
    /// picked at 11:20:34 UTC and IntelliJ was in front 0.6 seconds later, with nothing in between that
    /// the user could have done; what takes the front back is not known.
    @MainActor
    private func logOutcome(of window: WindowIdentity, app: AppIdentity, after path: String, repeatable: Repeat?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + outcomeDelay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let windowServer = self.windowServer
                let isVisible = windowServer.placement(of: window.windowID, ownedBy: app.processIdentifier) == .onScreen
                let frontmost = windowServer.frontmostProcessIdentifier()
                BokslTabDiagnosticLog.write(
                    "window-activation.\(path).verify " + Self.outcomeDescription(
                        window: window,
                        processIdentifier: app.processIdentifier,
                        isVisible: isVisible,
                        frontToBackWindowIDs: windowServer.onScreenWindows()
                            .compactMap(MRUWindowSnapshot.init(windowInfo:)).map(\.windowID),
                        frontmostProcessIdentifier: frontmost
                    )
                )
                guard let repeatable,
                      Self.shouldRepeatSwitch(
                          frontmostProcessIdentifier: frontmost,
                          targetProcessIdentifier: app.processIdentifier,
                          ownProcessIdentifier: getpid(),
                          targetWindowIsVisible: !repeatable.checksWindow || isVisible,
                          isLatestActivation: repeatable.activation == self.latestActivation
                      )
                else { return }
                await self.repeatSwitch(to: window, app: app, handle: repeatable.handle, frontmost: frontmost)
            }
        }
    }

    /// The switch did not hold when another app is in front, or the app is in front but shows another
    /// window. It is left alone when the user has moved on: the switcher's own panel is in front again,
    /// or a newer switch has started. Without knowing which app is in front there is nothing to repeat.
    static func shouldRepeatSwitch(
        frontmostProcessIdentifier: Int32?,
        targetProcessIdentifier: Int32,
        ownProcessIdentifier: Int32,
        targetWindowIsVisible: Bool,
        isLatestActivation: Bool
    ) -> Bool {
        guard isLatestActivation,
              let frontmostProcessIdentifier,
              frontmostProcessIdentifier != ownProcessIdentifier
        else { return false }
        return frontmostProcessIdentifier != targetProcessIdentifier || !targetWindowIsVisible
    }

    /// By now BokslTab is in the background, where an ordinary activation request may be turned down.
    /// The window server's request is not, so a window it can show is focused through it.
    @MainActor
    private func repeatSwitch(to window: WindowIdentity, app: AppIdentity, handle: AXUIElement?, frontmost: Int32?) async {
        let target = window.tab.map { "tab=\($0.index)" } ?? "window=\(window.windowID)"
        BokslTabDiagnosticLog.write(
            "window-activation.repeat pid=\(app.processIdentifier) \(target) frontmost=\(frontmost ?? -1)"
        )
        let placement: WindowServerPlacement = window.tab == nil
            ? windowServer.placement(of: window.windowID, ownedBy: app.processIdentifier)
            : .missing
        let focusedByWindowServer = (placement == .onScreen || placement == .offScreen)
            && windowServer.focus(window.windowID, app.processIdentifier) == .focused
        if !focusedByWindowServer {
            _ = appActivator.activate(app: app)
        }
        if let handle {
            let _: Bool? = await accessibility.run(
                for: app.processIdentifier, duration: 1, requestTimeout: 0.25
            ) { query in
                self.focusAndRaise(handle, query: query) == .success
            }
        }
        logOutcome(of: window, app: app, after: "repeat", repeatable: nil)
    }

    static func outcomeDescription(
        window: WindowIdentity,
        processIdentifier: Int32,
        isVisible: Bool,
        frontToBackWindowIDs: [String],
        frontmostProcessIdentifier: Int32?
    ) -> String {
        var fields = ["pid=\(processIdentifier)"]
        if let tab = window.tab {
            // The row names the tab bar's window; the tab's own window is not known yet.
            fields.append("tab=\(tab.index)")
        } else {
            let targetID = SwitcherItem.windowID(windowID: window.windowID, ownerProcessIdentifier: processIdentifier)
            fields.append("window=\(window.windowID)")
            fields.append("visible=\(isVisible)")
            fields.append("stackIndex=\(frontToBackWindowIDs.firstIndex(of: targetID).map(String.init) ?? "none")")
        }
        fields.append("frontmost=\(frontmostProcessIdentifier ?? -1)")
        fields.append("front=\(frontToBackWindowIDs.first.map { String($0.dropFirst("window:".count)) } ?? "none")")
        return fields.joined(separator: " ")
    }

    private func performActivation(
        _ target: Target,
        restoresMinimized: Bool,
        query: AccessibilityQueryBudget
    ) -> SwitchResult? {
        switch target {
        case .window(let window):
            // A minimized window is not raised by AXRaise alone. A window on screen cannot be minimized,
            // and every request spared matters for an app that is slow to answer.
            if restoresMinimized {
                _ = query.setAttribute(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            return focusAndRaise(window, query: query) == .success ? .exactWindowSuccess : nil
        case .tab(let match, let plan):
            let raiseError = plan == .focusParentThenSelect ? focusAndRaise(match.window, query: query) : nil
            let selection = select(tab: match.tab.element, query: query)
            BokslTabDiagnosticLog.write("window-activation.ax.tab.select method=\(selection.method) success=\(selection.success)")
            if selection.success {
                return raiseError == nil || raiseError == .success ? .exactWindowSuccess : .limitedAppFallbackSuccess
            }
            return (raiseError ?? focusAndRaise(match.window, query: query)) == .success
                ? .limitedAppFallbackSuccess : nil
        }
    }

    private func findAXWindowAndTab(
        matching window: WindowIdentity,
        app: AppIdentity,
        query: AccessibilityQueryBudget
    ) -> AXWindowTabMatch? {
        guard let targetTab = window.tab else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axWindows(from: appElement, query: query), !windows.isEmpty else { return nil }
        let parentCandidates = parentCandidateWindows(for: targetTab, windows: windows, query: query)
        BokslTabDiagnosticLog.write(
            "window-activation.ax.tab.parent strategy=\(parentCandidates.strategy) candidates=\(parentCandidates.windows.count) pid=\(app.processIdentifier) parentWindow=\(targetTab.parentWindowID)"
        )

        let matches = parentCandidates.windows.compactMap { candidateWindow -> AXWindowTabMatch? in
            let tabs = AXTabElementSnapshot.tabs(in: candidateWindow, query: query)
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
        windows: [AXUIElement],
        query: AccessibilityQueryBudget
    ) -> AXParentWindowCandidateResolution<AXUIElement> {
        if let index = AXWindowMatchPolicy.windowIDMatchIndex(
            targetWindowID: targetTab.parentWindowID,
            candidateWindowIDs: windows.map { query.windowID(of: $0) }
        ) {
            return AXParentWindowCandidateResolution(windows: [windows[index]], strategy: "window-id")
        }
        // Merged IDE windows can be re-created under a new number, so geometry and title still apply.
        let resolution = AXParentWindowMatchPolicy.candidateIndices(
            target: targetTab,
            candidateTitles: windows.map { title(of: $0, query: query) },
            candidateFrames: windows.map { query.reader.frame(of: $0) }
        )
        return AXParentWindowCandidateResolution(
            windows: resolution.indices.map { windows[$0] },
            strategy: resolution.strategy
        )
    }

    /// The row's window number is authoritative: two maximized windows of one app share geometry,
    /// and a row's title is only as reliable as the catalog's guess when that number was unknown.
    private func findAXWindow(matching window: WindowIdentity, app: AppIdentity, query: AccessibilityQueryBudget) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // An app whose windows all sit on other Spaces may list none; remembered handles still apply.
        let windows = axWindows(from: appElement, query: query) ?? []

        let windowIDs = windows.map { query.windowID(of: $0) }
        for (element, windowID) in zip(windows, windowIDs) {
            guard let windowID else { continue }
            accessibility.windowElements.record(element, windowID: windowID, processIdentifier: app.processIdentifier)
        }
        if let matchedIndex = AXWindowMatchPolicy.windowIDMatchIndex(
            targetWindowID: window.windowID,
            candidateWindowIDs: windowIDs
        ) {
            BokslTabDiagnosticLog.write(
                "window-activation.target by=window-id pid=\(app.processIdentifier) window=\(window.windowID)"
            )
            return windows[matchedIndex]
        }
        if let remembered = rememberedAXWindow(matching: window, app: app, query: query) {
            return remembered
        }

        guard let targetTitle = window.title?.nonBlankForAdapter else { return nil }
        let titleCandidateIndices = AXWindowMatchPolicy.titleCandidateIndices(
            candidateWindowIDs: windowIDs,
            targetHasWindowServerID: window.source == .coreGraphics
        )
        let candidateTitles = titleCandidateIndices.map { title(of: windows[$0], query: query) }
        guard let localIndex = AXWindowMatchPolicy.uniqueTitleMatchIndex(
            targetTitle: targetTitle,
            candidateTitles: candidateTitles
        ) else { return nil }

        BokslTabDiagnosticLog.write(
            "window-activation.target by=title pid=\(app.processIdentifier) window=\(window.windowID) candidates=\(titleCandidateIndices.count)/\(windows.count)"
        )
        return windows[titleCandidateIndices[localIndex]]
    }

    /// AX lists only what the current Space shows. A handle recorded while the window was visible still
    /// reaches it on another desktop, in full screen, or as an unselected tab of a native tab group;
    /// raising that handle selects the tab.
    private func rememberedAXWindow(matching window: WindowIdentity, app: AppIdentity, query: AccessibilityQueryBudget) -> AXUIElement? {
        let windows = accessibility.windowElements
        guard let element = windows.element(windowID: window.windowID, processIdentifier: app.processIdentifier) else {
            return nil
        }
        guard query.windowID(of: element) == window.windowID else {
            windows.remove(windowID: window.windowID, processIdentifier: app.processIdentifier)
            BokslTabDiagnosticLog.write(
                "window-activation.ax.remembered-handle result=stale pid=\(app.processIdentifier) window=\(window.windowID)"
            )
            return nil
        }
        BokslTabDiagnosticLog.write(
            "window-activation.ax.remembered-handle result=hit pid=\(app.processIdentifier) window=\(window.windowID)"
        )
        return element
    }

    private func axWindows(from appElement: AXUIElement, query: AccessibilityQueryBudget) -> [AXUIElement]? {
        var rawWindows: CFTypeRef?
        let copyError = query.copyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard copyError == .success else { return nil }
        return rawWindows as? [AXUIElement]
    }

    private func select(tab: AXUIElement, query: AccessibilityQueryBudget) -> AXTabSelectionResult {
        let pressError = query.performAction(tab, kAXPressAction as CFString)
        if pressError == .success {
            return AXTabSelectionResult(success: true, method: "press", errorCode: nil)
        }

        let selectedError = query.setAttribute(tab, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if selectedError == .success {
            return AXTabSelectionResult(success: true, method: "selected-attribute", errorCode: nil)
        }

        return AXTabSelectionResult(success: false, method: "fallback", errorCode: selectedError.rawValue)
    }

    private func focusAndRaise(_ axWindow: AXUIElement, query: AccessibilityQueryBudget) -> AXError {
        _ = query.setAttribute(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = query.setAttribute(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return query.performAction(axWindow, kAXRaiseAction as CFString)
    }

    private func title(of window: AXUIElement, query: AccessibilityQueryBudget) -> String? {
        var rawTitle: CFTypeRef?
        guard query.copyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else {
            return nil
        }
        return rawTitle as? String
    }

    @MainActor
    private func fallbackToApp(
        window: WindowIdentity,
        app: AppIdentity,
        activation: Int,
        intent: AppActivationIntent = .focusOnly,
        reason: String
    ) -> SwitchResult {
        BokslTabDiagnosticLog.write(
            "window-activation.fallback intent=\(intent) pid=\(app.processIdentifier) reason=\(reason)"
        )
        let activationResult = appActivator.activate(app: app, intent: intent)
        logOutcome(
            of: window, app: app, after: "fallback",
            repeatable: Repeat(activation: activation, handle: nil, checksWindow: false)
        )

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
    static func windowIDMatchIndex(targetWindowID: UInt32, candidateWindowIDs: [UInt32?]) -> Int? {
        candidateWindowIDs.firstIndex { $0 == targetWindowID }
    }

    /// A window-server row whose number matched nothing must not borrow an identified window by title:
    /// that window is known to be a different one. Other rows keep title matching across all windows.
    static func titleCandidateIndices(candidateWindowIDs: [UInt32?], targetHasWindowServerID: Bool) -> [Int] {
        guard targetHasWindowServerID else { return Array(candidateWindowIDs.indices) }
        return candidateWindowIDs.indices.filter { candidateWindowIDs[$0] == nil }
    }

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

    static func tabs(in window: AXUIElement, query: AccessibilityQueryBudget) -> [AXTabElementSnapshot] {
        let tabElements = AccessibilityTabResolver.resolveElements(in: window, query: query).elements

        return tabElements.enumerated().map { index, element in
            AXTabElementSnapshot(
                index: index,
                title: AccessibilityTabResolver.title(of: element, query: query),
                isSelected: AccessibilityTabResolver.isSelected(element, query: query),
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
