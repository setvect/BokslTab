import AppKit
import BokslTabCore
import BokslTabMacOSAdapters
import BokslTabUI
import SwiftUI

@MainActor
final class SwitcherCoordinator {
    private let runningAppProvider: RunningAppProviding
    private let windowCatalogProvider: WindowCatalogProviding
    private let appActivator: AppActivating
    private let windowActivator: WindowActivating
    private let permissionAdvisor: PermissionAdvising
    private let macOSPermissionAdvisor: MacOSPermissionAdvisor?
    private let mruOrderingProvider: SwitcherMRUOrderingProviding
    private let hotkeyService: GlobalHotkeyServicing
    private lazy var panelController = SwitcherPanelController(
        iconProvider: { [weak self] item in self?.icon(for: item.app) },
        onKeyboardAction: { [weak self] action in self?.handle(action: action) },
        onOpenSettings: { [weak self] in self?.openPermissionSettings() },
        diagnosticLog: { BokslTabDiagnosticLog.write($0) }
    )

    private var activationTask: Task<Void, Never>?
    private var state = SwitcherState(mode: .allAppsAndWindows, items: [])
    private var currentWarning: String?
    private var startupWarning: String?
    private var previousFrontmostApp: AppIdentity?
    private var presentedApps: [AppIdentity] = []
    private var presentedActiveApp: AppIdentity?

    init(
        runningAppProvider: RunningAppProviding,
        windowCatalogProvider: WindowCatalogProviding,
        appActivator: AppActivating,
        windowActivator: WindowActivating,
        permissionAdvisor: PermissionAdvising,
        mruOrderingProvider: SwitcherMRUOrderingProviding,
        hotkeyService: GlobalHotkeyServicing
    ) {
        self.runningAppProvider = runningAppProvider
        self.windowCatalogProvider = windowCatalogProvider
        self.appActivator = appActivator
        self.windowActivator = windowActivator
        self.permissionAdvisor = permissionAdvisor
        self.macOSPermissionAdvisor = permissionAdvisor as? MacOSPermissionAdvisor
        self.mruOrderingProvider = mruOrderingProvider
        self.hotkeyService = hotkeyService
    }

    func start() {
        (windowCatalogProvider as? WindowCatalogRefreshing)?.onDidRefresh = { [weak self] in
            self?.refreshVisibleItems()
        }
        // Warm details before the first keyboard gesture, without waiting for AX responses.
        (windowCatalogProvider as? WindowCatalogRefreshing)?.requestRefresh(including: runningAppProvider.runningApps())
        let allAppsDefinition = SwitcherMode.allAppsAndWindows.defaultHotkeyDefinition
        let activeAppDefinition = SwitcherMode.activeAppWindows.defaultHotkeyDefinition
        let definitions = [
            allAppsDefinition,
            activeAppDefinition
        ]

        do {
            try registerHotkeys(definitions)
        } catch {
            reportStartupDiagnostic("전역 단축키 등록 실패: \(error)")
            retryPrimaryHotkeyIfActiveAppHotkeyConflicted(
                error: error,
                primaryDefinition: allAppsDefinition,
                conflictingDefinition: activeAppDefinition
            )
        }
    }

    private func registerHotkeys(_ definitions: [HotkeyDefinition]) throws {
        BokslTabDiagnosticLog.write("coordinator.registerHotkeys definitions=\(definitions.map(\.description).joined(separator: ", "))")
        try hotkeyService.start(definitions: definitions) { [weak self] mode in
            BokslTabDiagnosticLog.write("coordinator.hotkeyReceived mode=\(mode.rawValue)")
            DispatchQueue.main.async {
                self?.show(mode: mode, expectsModifierRelease: true)
            }
        }
    }

    private func retryPrimaryHotkeyIfActiveAppHotkeyConflicted(
        error: Error,
        primaryDefinition: HotkeyDefinition,
        conflictingDefinition: HotkeyDefinition
    ) {
        if case HotkeyRegistrationError.partialRegistrationFailed(let failures) = error {
            let activeAppHotkeyFailed = failures.contains { $0.definition == conflictingDefinition }
            guard activeAppHotkeyFailed else { return }

            retryPrimaryHotkey(primaryDefinition, conflictingDefinition: conflictingDefinition)
            return
        }

        guard case HotkeyRegistrationError.registrationFailed(let failedDefinition, _) = error,
              failedDefinition == conflictingDefinition
        else { return }

        retryPrimaryHotkey(primaryDefinition, conflictingDefinition: conflictingDefinition)
    }

    private func retryPrimaryHotkey(
        _ primaryDefinition: HotkeyDefinition,
        conflictingDefinition: HotkeyDefinition
    ) {
        do {
            try registerHotkeys([primaryDefinition])
            reportActiveAppHotkeyFallback(conflictingDefinition)
        } catch {
            reportStartupDiagnostic("기본 단축키 대체 등록 실패: \(error)")
        }
    }

    private func reportActiveAppHotkeyFallback(_ conflictingDefinition: HotkeyDefinition) {
        let message = "활성 앱 단축키 \(conflictingDefinition) 등록 실패로 모든 앱 단축키만 유지합니다."
        startupWarning = message
        reportDiagnostic(message)
    }

    func stop() {
        BokslTabDiagnosticLog.write("coordinator.stop")
        (windowCatalogProvider as? WindowCatalogRefreshing)?.onDidRefresh = nil
        activationTask?.cancel()
        hotkeyService.stop()
    }

    func show(mode: SwitcherMode, expectsModifierRelease: Bool = false) {
        activationTask?.cancel()
        BokslTabDiagnosticLog.write("coordinator.show requested mode=\(mode.rawValue) panelVisible=\(panelController.isVisible)")
        if panelController.isVisible, state.mode == mode {
            state.moveNext()
            panelController.update(state: state, warning: currentWarning)
            panelController.setExpectsModifierRelease(expectsModifierRelease)
            return
        }

        (windowCatalogProvider as? WindowCatalogRefreshing)?.requestRefresh(including: runningAppProvider.runningApps())
        rememberPreviousFrontmostApp()
        let presentation = presentation(for: mode)
        state = SwitcherState(
            mode: mode,
            items: presentation.items,
            selectedIndex: presentation.selectedIndex
        )
        currentWarning = permissionWarning(for: mode) ?? startupWarning
        panelController.show(
            state: state,
            warning: currentWarning,
            expectsModifierRelease: expectsModifierRelease
        )
    }

    private func handle(action: SwitcherKeyboardAction) {
        switch action {
        case .next:
            state.moveNext()
            panelController.update(state: state, warning: currentWarning)
        case .previous:
            state.movePrevious()
            panelController.update(state: state, warning: currentWarning)
        case .confirm:
            activateSelectedItem()
        case .cancel:
            cancelAndRestoreFocus()
        case .modifierReleased:
            activateSelectedItem()
        case .focusLost:
            dismissPanelWithoutRestoringFocus()
        case .select(let index):
            state.select(index: index)
            panelController.update(state: state, warning: currentWarning)
        case .activate(let index):
            state.select(index: index)
            activateSelectedItem()
        }
    }

    private func activateSelectedItem() {
        guard let item = state.selectedItem else {
            cancelAndRestoreFocus()
            return
        }

        panelController.hide()
        previousFrontmostApp = nil
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let result: SwitchResult
            switch item.kind {
            case .app:
                result = appActivator.activate(app: item.app, intent: .reopenIfNeeded)
            case .window(let window):
                result = await windowActivator.activate(window: window, app: item.app)
            }
            guard !Task.isCancelled else { return }
            recordActivatedItem(item, result: result)
            reportSwitchResult(result)
        }
    }

    private func recordActivatedItem(_ item: SwitcherItem, result: SwitchResult) {
        guard let historyRecorder = mruOrderingProvider as? SwitcherMRUHistoryRecording else { return }

        switch result {
        case .exactWindowSuccess:
            historyRecorder.recordActivatedItem(item)
        case .appActivationSuccess:
            historyRecorder.recordActivatedApp(item.app)
        case .limitedAppFallbackSuccess:
            historyRecorder.recordActivatedApp(item.app)
        case .safeFailure:
            return
        }
    }

    private func cancelAndRestoreFocus() {
        panelController.hide()
        defer { previousFrontmostApp = nil }
        guard let previousFrontmostApp else { return }
        _ = appActivator.activate(app: previousFrontmostApp)
    }

    private func dismissPanelWithoutRestoringFocus() {
        panelController.hide()
        previousFrontmostApp = nil
    }

    private func rememberPreviousFrontmostApp() {
        guard let app = runningAppProvider.frontmostApp(), app.processIdentifier != getpid() else {
            previousFrontmostApp = nil
            return
        }
        previousFrontmostApp = app
    }

    private struct SwitcherPresentation {
        let items: [SwitcherItem]
        let selectedIndex: Int
    }

    private func refreshVisibleItems() {
        guard panelController.isVisible else { return }
        let presentation = presentation(for: state.mode, refreshing: true)
        if state.mergeRefreshedItems(presentation.items) {
            panelController.update(state: state, warning: currentWarning)
        }
    }

    private func presentation(for mode: SwitcherMode, refreshing: Bool = false) -> SwitcherPresentation {
        switch mode {
        case .allAppsAndWindows:
            let apps = refreshing ? presentedApps : runningAppProvider.runningApps()
            if !refreshing { presentedApps = apps }
            let windows = windowCatalogProvider.windowsForAllApps(including: apps)
            let items = SwitcherItemComposer.composeAllAppsAndWindows(
                apps: apps,
                windows: windows,
                currentProcessIdentifier: getpid()
            )
            return refreshing
                ? SwitcherPresentation(items: items, selectedIndex: state.selectedIndex)
                : orderForMRU(mode: mode, items: items)
        case .activeAppWindows:
            if !refreshing { presentedActiveApp = runningAppProvider.frontmostApp() }
            guard let app = presentedActiveApp else {
                return SwitcherPresentation(items: [], selectedIndex: 0)
            }
            let items = SwitcherItemComposer.composeActiveAppWindows(
                app: app,
                windows: windowCatalogProvider.windows(for: app)
            )
            return refreshing
                ? SwitcherPresentation(items: items, selectedIndex: state.selectedIndex)
                : orderForMRU(mode: mode, items: items)
        }
    }

    private func orderForMRU(mode: SwitcherMode, items: [SwitcherItem]) -> SwitcherPresentation {
        let context = mruOrderingProvider.orderingContext(for: mode, items: items)
        let orderedItems = SwitcherMRUOrderer.order(items: items, context: context)
        let selectedIndex = SwitcherMRUOrderer.defaultSelectedIndex(
            orderedItems: orderedItems,
            context: context
        )
        let diagnostics = SwitcherMRUOrderer.diagnostics(items: items, context: context)
        BokslTabDiagnosticLog.write(
            "mru.order mode=\(mode.rawValue) source=\(context.sourceDescription) fallback=\(context.fallbackReason ?? "none") partialFallback=\(diagnostics.partialFallbackReason ?? "none") items=\(items.count) ordered=\(orderedItems.count) selectedIndex=\(selectedIndex) matched=\(diagnostics.matchedItemCount) unmatched=\(diagnostics.unmatchedItemCount) current=\(context.currentItemID ?? "none") orderedIDs=\(orderedItems.map(\.id).joined(separator: ","))"
        )
        return SwitcherPresentation(items: orderedItems, selectedIndex: selectedIndex)
    }

    private func permissionWarning(for mode: SwitcherMode) -> String? {
        switch permissionAdvisor.accessibility {
        case .denied(let reason):
            return reason
        case .allowed, .unknown:
            return nil
        }
    }

    private func reportSwitchResult(_ result: SwitchResult) {
        switch result {
        case .exactWindowSuccess, .appActivationSuccess:
            break
        case .limitedAppFallbackSuccess:
            reportDiagnostic("정확한 창 전환 대신 앱 활성화로 대체했습니다.")
        case .safeFailure(let reason):
            reportDiagnostic("전환 실패: \(reason)")
        }
    }

    private func reportStartupDiagnostic(_ message: String) {
        startupWarning = message
        reportDiagnostic(message)
    }

    private func reportDiagnostic(_ message: String) {
        currentWarning = message
        fputs("BokslTab: \(message)\n", stderr)
    }

    private func openPermissionSettings() {
        _ = macOSPermissionAdvisor?.requestAccessibilityPrompt()
        let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(accessibilityURL) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    fputs("BokslTab: 시스템 설정 열기 실패: \(error)\n", stderr)
                }
            }
        }
    }

    private func icon(for app: AppIdentity) -> NSImage? {
        NSRunningApplication(processIdentifier: app.processIdentifier)?.icon
    }
}
