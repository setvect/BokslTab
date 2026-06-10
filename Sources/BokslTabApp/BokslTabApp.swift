import AppKit
import BokslTabCore
import BokslTabMacOSAdapters
import BokslTabUI
import SwiftUI

@main
struct BokslTabApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("BokslTab", systemImage: "rectangle.stack") {
            Button("모든 앱/창 보기") {
                appDelegate.coordinator?.show(mode: .allAppsAndWindows)
            }
            .keyboardShortcut("1")

            Button("활성 앱 창 보기") {
                appDelegate.coordinator?.show(mode: .activeAppWindows)
            }
            .keyboardShortcut("2")

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: SwitcherCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--restore-native-command-tab") {
            runNativeCommandTabRestoreAndExit()
            return
        }

        if CommandLine.arguments.contains("--smoke-test") {
            runSmokeTestAndExit()
            return
        }

        BokslTabDiagnosticLog.write("app.launch pid=\(getpid()) logPath=\(BokslTabDiagnosticLog.filePath)")
        NSApp.setActivationPolicy(.accessory)
        let coordinator = SwitcherCoordinator(
            runningAppProvider: MacOSRunningAppProvider(),
            windowCatalogProvider: MacOSWindowCatalogProvider(),
            appActivator: MacOSAppActivator(),
            windowActivator: MacOSWindowActivator(),
            permissionAdvisor: MacOSPermissionAdvisor(),
            mruOrderingProvider: MacOSMRUOrderingProvider(),
            hotkeyService: PrioritizedGlobalHotkeyService()
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    private func runSmokeTestAndExit() {
        let runningAppProvider = MacOSRunningAppProvider()
        let windowCatalogProvider = MacOSWindowCatalogProvider()
        let permissionAdvisor = MacOSPermissionAdvisor()
        let apps = runningAppProvider.runningApps()
        let windows = windowCatalogProvider.windowsForAllApps(including: apps)
        let composedItems = SwitcherItemComposer.composeAllAppsAndWindows(
            apps: apps,
            windows: windows,
            currentProcessIdentifier: getpid()
        )

        print("BokslTab smoke-test")
        print("regularApps=\(apps.count)")
        print("windows=\(windows.count)")
        print("switcherItems=\(composedItems.count)")
        print("accessibility=\(permissionAdvisor.accessibility)")
        print("screenMetadata=\(permissionAdvisor.screenMetadata)")
        NSApplication.shared.terminate(nil)
    }

    private func runNativeCommandTabRestoreAndExit() {
        let succeeded = NativeCommandTabHotkeyRecovery.enableCommandTabPair()
        print("nativeCommandTabRestore=\(succeeded ? "succeeded" : "failed")")
        NSApplication.shared.terminate(nil)
    }
}

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

    private var state = SwitcherState(mode: .allAppsAndWindows, items: [])
    private var currentWarning: String?
    private var startupWarning: String?
    private var previousFrontmostApp: AppIdentity?

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
            let primaryHotkeyFailed = failures.contains { $0.definition == primaryDefinition }
            guard activeAppHotkeyFailed else { return }

            if !primaryHotkeyFailed {
                reportActiveAppHotkeyFallback(conflictingDefinition)
                return
            }

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
        hotkeyService.stop()
    }

    func show(mode: SwitcherMode, expectsModifierRelease: Bool = false) {
        BokslTabDiagnosticLog.write("coordinator.show requested mode=\(mode.rawValue) panelVisible=\(panelController.isVisible)")
        if panelController.isVisible, state.mode == mode {
            state.moveNext()
            panelController.update(state: state, warning: currentWarning)
            panelController.setExpectsModifierRelease(expectsModifierRelease)
            return
        }

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
        let result: SwitchResult
        switch item.kind {
        case .app:
            result = appActivator.activate(app: item.app, intent: .reopenIfNeeded)
        case .window(let window):
            result = windowActivator.activate(window: window, app: item.app)
        }
        recordActivatedItem(item, result: result)
        reportSwitchResult(result)
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

    private func presentation(for mode: SwitcherMode) -> SwitcherPresentation {
        switch mode {
        case .allAppsAndWindows:
            let apps = runningAppProvider.runningApps()
            let windows = windowCatalogProvider.windowsForAllApps(including: apps)
            let items = SwitcherItemComposer.composeAllAppsAndWindows(
                apps: apps,
                windows: windows,
                currentProcessIdentifier: getpid()
            )
            return orderForMRU(mode: mode, items: items)
        case .activeAppWindows:
            guard let app = runningAppProvider.frontmostApp() else {
                return SwitcherPresentation(items: [], selectedIndex: 0)
            }
            let items = SwitcherItemComposer.composeActiveAppWindows(
                app: app,
                windows: windowCatalogProvider.windows(for: app)
            )
            return orderForMRU(mode: mode, items: items)
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
            "mru.order mode=\(mode.rawValue) source=\(context.sourceDescription) fallback=\(context.fallbackReason ?? "none") partialFallback=\(diagnostics.partialFallbackReason ?? "none") items=\(items.count) ordered=\(orderedItems.count) selectedIndex=\(selectedIndex) matched=\(diagnostics.matchedItemCount) unmatched=\(diagnostics.unmatchedItemCount) current=\(context.currentItemID ?? "none")"
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
