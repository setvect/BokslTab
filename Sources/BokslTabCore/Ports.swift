import Foundation

public protocol RunningAppProviding {
    func runningApps() -> [AppIdentity]
    func frontmostApp() -> AppIdentity?
}

public protocol WindowCatalogProviding {
    func windowsForAllApps() -> [WindowIdentity]
    func windows(for app: AppIdentity) -> [WindowIdentity]
}

public protocol AppActivating {
    func activate(app: AppIdentity) -> SwitchResult
}

public protocol WindowActivating {
    func activate(window: WindowIdentity, app: AppIdentity) -> SwitchResult
}

public protocol PermissionAdvising {
    var accessibility: PermissionState { get }
    var screenMetadata: PermissionState { get }
}

public struct HotkeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)
}

public struct HotkeyDefinition: Hashable, Sendable {
    public let mode: SwitcherMode
    public let keyCode: UInt32
    public let modifiers: HotkeyModifiers

    public init(mode: SwitcherMode, keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.mode = mode
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public protocol GlobalHotkeyServicing: AnyObject {
    func start(definitions: [HotkeyDefinition], onTrigger: @escaping @Sendable (SwitcherMode) -> Void) throws
    func stop()
}

public enum HotkeyRegistrationError: Error, Equatable, Sendable {
    case handlerInstallFailed(code: Int32)
    case registrationFailed(mode: SwitcherMode, code: Int32)
}
