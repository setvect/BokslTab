import AppKit
import BokslTabCore
import Foundation

public final class MacOSRunningAppProvider: RunningAppProviding {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func runningApps() -> [AppIdentity] {
        workspace.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(AppIdentity.init(runningApplication:))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func frontmostApp() -> AppIdentity? {
        guard let app = workspace.frontmostApplication,
              app.activationPolicy == .regular,
              !app.isTerminated
        else { return nil }
        return AppIdentity(runningApplication: app)
    }
}

private extension AppIdentity {
    init(runningApplication app: NSRunningApplication) {
        self.init(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            processName: app.executableURL?.deletingPathExtension().lastPathComponent
        )
    }
}
