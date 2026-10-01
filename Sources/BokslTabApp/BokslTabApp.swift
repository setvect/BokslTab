import AppKit
import BokslTabCore
import BokslTabMacOSAdapters
import BokslTabUI
import SwiftUI

@main
struct BokslTabApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("모든 앱/창 보기") {
                appDelegate.coordinator?.show(mode: .allAppsAndWindows)
            }
            .keyboardShortcut("1")

            Button("활성 앱 창 보기") {
                appDelegate.coordinator?.show(mode: .activeAppWindows)
            }
            .keyboardShortcut("2")

            Divider()

            Button("BokslTab 종료") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(nsImage: BokslTabMenuBarIcon.image)
        }
    }
}

private enum BokslTabMenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 22))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setStroke()

        let outline = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 5.0, width: 15.0, height: 12.0), xRadius: 3.0, yRadius: 3.0)
        outline.lineWidth = 1.8
        outline.stroke()

        let arrow = NSBezierPath()
        arrow.lineWidth = 1.9
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 7.1, y: 11.0))
        arrow.line(to: NSPoint(x: 13.4, y: 11.0))
        arrow.move(to: NSPoint(x: 11.3, y: 8.8))
        arrow.line(to: NSPoint(x: 13.7, y: 11.0))
        arrow.line(to: NSPoint(x: 11.3, y: 13.2))
        arrow.stroke()

        let tabStop = NSBezierPath()
        tabStop.lineWidth = 1.9
        tabStop.lineCapStyle = .round
        tabStop.move(to: NSPoint(x: 15.6, y: 8.3))
        tabStop.line(to: NSPoint(x: 15.6, y: 13.7))
        tabStop.stroke()

        image.isTemplate = true
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: SwitcherCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BokslTabDiagnosticLog.enableFileLogging(includeDebug: CommandLine.arguments.contains("--debug-logging"))
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
        let accessibility = MacOSAccessibilityService()
        let coordinator = SwitcherCoordinator(
            runningAppProvider: MacOSRunningAppProvider(),
            windowCatalogProvider: MacOSWindowCatalogProvider(accessibility: accessibility),
            appActivator: MacOSAppActivator(),
            windowActivator: MacOSWindowActivator(accessibility: accessibility),
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
