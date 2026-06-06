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
        if CommandLine.arguments.contains("--smoke-test") {
            runSmokeTestAndExit()
            return
        }

        NSApp.setActivationPolicy(.accessory)
        let coordinator = SwitcherCoordinator(
            runningAppProvider: MacOSRunningAppProvider(),
            windowCatalogProvider: MacOSWindowCatalogProvider(),
            appActivator: MacOSAppActivator(),
            windowActivator: MacOSWindowActivator(),
            permissionAdvisor: MacOSPermissionAdvisor(),
            hotkeyService: CarbonGlobalHotkeyService()
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
        let windows = windowCatalogProvider.windowsForAllApps()
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
}

@MainActor
final class SwitcherCoordinator {
    private let runningAppProvider: RunningAppProviding
    private let windowCatalogProvider: WindowCatalogProviding
    private let appActivator: AppActivating
    private let windowActivator: WindowActivating
    private let permissionAdvisor: PermissionAdvising
    private let hotkeyService: GlobalHotkeyServicing
    private lazy var panelController = SwitcherPanelController(
        iconProvider: { [weak self] item in self?.icon(for: item.app) },
        onKeyboardAction: { [weak self] action in self?.handle(action: action) }
    )

    private var state = SwitcherState(mode: .allAppsAndWindows, items: [])
    private var currentWarning: String?
    private var previousFrontmostApp: AppIdentity?

    init(
        runningAppProvider: RunningAppProviding,
        windowCatalogProvider: WindowCatalogProviding,
        appActivator: AppActivating,
        windowActivator: WindowActivating,
        permissionAdvisor: PermissionAdvising,
        hotkeyService: GlobalHotkeyServicing
    ) {
        self.runningAppProvider = runningAppProvider
        self.windowCatalogProvider = windowCatalogProvider
        self.appActivator = appActivator
        self.windowActivator = windowActivator
        self.permissionAdvisor = permissionAdvisor
        self.hotkeyService = hotkeyService
    }

    func start() {
        let definitions = [
            HotkeyDefinition(mode: .allAppsAndWindows, keyCode: 48, modifiers: [.option]),
            HotkeyDefinition(mode: .activeAppWindows, keyCode: 50, modifiers: [.option])
        ]

        do {
            try hotkeyService.start(definitions: definitions) { [weak self] mode in
                DispatchQueue.main.async {
                    self?.show(mode: mode)
                }
            }
        } catch {
            reportDiagnostic("전역 단축키 등록 실패: \(error)")
        }
    }

    func stop() {
        hotkeyService.stop()
    }

    func show(mode: SwitcherMode) {
        if panelController.isVisible, state.mode == mode {
            state.moveNext()
            panelController.update(state: state, warning: currentWarning)
            return
        }

        rememberPreviousFrontmostApp()
        state = SwitcherState(mode: mode, items: items(for: mode))
        currentWarning = permissionWarning(for: mode)
        panelController.show(state: state, warning: currentWarning)
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
            result = appActivator.activate(app: item.app)
        case .window(let window):
            result = windowActivator.activate(window: window, app: item.app)
        }
        reportSwitchResult(result)
    }

    private func cancelAndRestoreFocus() {
        panelController.hide()
        defer { previousFrontmostApp = nil }
        guard let previousFrontmostApp else { return }
        _ = appActivator.activate(app: previousFrontmostApp)
    }

    private func rememberPreviousFrontmostApp() {
        guard let app = runningAppProvider.frontmostApp(), app.processIdentifier != getpid() else {
            previousFrontmostApp = nil
            return
        }
        previousFrontmostApp = app
    }

    private func items(for mode: SwitcherMode) -> [SwitcherItem] {
        switch mode {
        case .allAppsAndWindows:
            return SwitcherItemComposer.composeAllAppsAndWindows(
                apps: runningAppProvider.runningApps(),
                windows: windowCatalogProvider.windowsForAllApps(),
                currentProcessIdentifier: getpid()
            )
        case .activeAppWindows:
            guard let app = runningAppProvider.frontmostApp() else { return [] }
            return SwitcherItemComposer.composeActiveAppWindows(
                app: app,
                windows: windowCatalogProvider.windows(for: app)
            )
        }
    }

    private func permissionWarning(for mode: SwitcherMode) -> String? {
        switch permissionAdvisor.accessibility {
        case .denied(let reason):
            return reason
        case .allowed, .unknown:
            break
        }

        switch permissionAdvisor.screenMetadata {
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

    private func reportDiagnostic(_ message: String) {
        currentWarning = message
        fputs("BokslTab: \(message)\n", stderr)
    }

    private func icon(for app: AppIdentity) -> NSImage? {
        NSRunningApplication(processIdentifier: app.processIdentifier)?.icon
    }
}
