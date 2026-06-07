import Foundation

public protocol RunningAppProviding {
    func runningApps() -> [AppIdentity]
    func frontmostApp() -> AppIdentity?
}

public protocol WindowCatalogProviding {
    func windowsForAllApps() -> [WindowIdentity]
    func windowsForAllApps(including apps: [AppIdentity]) -> [WindowIdentity]
    func windows(for app: AppIdentity) -> [WindowIdentity]
}

public extension WindowCatalogProviding {
    func windowsForAllApps(including apps: [AppIdentity]) -> [WindowIdentity] {
        windowsForAllApps()
    }
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

public struct HotkeyRegistrationFailure: Equatable, Sendable {
    public let definition: HotkeyDefinition
    public let code: Int32

    public init(definition: HotkeyDefinition, code: Int32) {
        self.definition = definition
        self.code = code
    }
}

public enum HotkeyRegistrationError: Error, Equatable, Sendable {
    case handlerInstallFailed(code: Int32)
    case registrationFailed(definition: HotkeyDefinition, code: Int32)
    case partialRegistrationFailed(failures: [HotkeyRegistrationFailure])
}

public extension SwitcherMode {
    var defaultHotkeyDefinition: HotkeyDefinition {
        switch self {
        case .allAppsAndWindows:
            return HotkeyDefinition(mode: self, keyCode: 48, modifiers: [.command])
        case .activeAppWindows:
            return HotkeyDefinition(mode: self, keyCode: 48, modifiers: [.option])
        }
    }
}

extension HotkeyModifiers: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.command) { parts.append("Cmd") }
        if contains(.option) { parts.append("Option") }
        if contains(.control) { parts.append("Control") }
        if contains(.shift) { parts.append("Shift") }
        return parts.isEmpty ? "None" : parts.joined(separator: "+")
    }
}

extension HotkeyDefinition: CustomStringConvertible {
    public var description: String {
        "mode=\(mode.rawValue), hotkey=\(modifiers)+keyCode(\(keyCode))"
    }
}

extension HotkeyRegistrationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .handlerInstallFailed(let code):
            return "handlerInstallFailed(code: \(code))"
        case .registrationFailed(let definition, let code):
            return "registrationFailed(\(definition), code: \(code))"
        case .partialRegistrationFailed(let failures):
            let details = failures
                .map { "\($0.definition), code: \($0.code)" }
                .joined(separator: "; ")
            return "partialRegistrationFailed(\(details))"
        }
    }
}
