import Darwin
import Foundation

enum NativeCommandTabSymbolicHotKey: Int, CaseIterable, Sendable {
    case commandTab = 1
    case commandShiftTab = 2
}

protocol NativeCommandTabHotkeyServicing: AnyObject {
    @discardableResult
    func disableCommandTabPair() -> Bool
    func restore()
}

typealias SetSymbolicHotKeyEnabled = @convention(c) (Int, Bool) -> Int32
typealias IsSymbolicHotKeyEnabled = @convention(c) (Int) -> Bool

public enum NativeCommandTabHotkeyRecovery {
    @discardableResult
    public static func enableCommandTabPair() -> Bool {
        enableCommandTabPair(loader: SkyLightSymbolLoader())
    }

    @discardableResult
    static func enableCommandTabPair(loader: SkyLightSymbolLoading) -> Bool {
        guard let symbols = loader.load() else {
            BokslTabDiagnosticLog.write("native-hotkey.recovery failed; SkyLight symbols unavailable")
            return false
        }

        var succeeded = true
        for hotkey in NativeCommandTabSymbolicHotKey.allCases {
            let result = symbols.setEnabled(hotkey.rawValue, true)
            BokslTabDiagnosticLog.write("native-hotkey.recovery enable id=\(hotkey.rawValue) result=\(result)")
            succeeded = succeeded && result == 0
        }
        return succeeded
    }
}

final class NativeCommandTabHotkeyService: NativeCommandTabHotkeyServicing {
    private let loader: SkyLightSymbolLoading
    private var originalStates: [NativeCommandTabSymbolicHotKey: Bool] = [:]

    init(loader: SkyLightSymbolLoading = SkyLightSymbolLoader()) {
        self.loader = loader
    }

    deinit {
        restore()
    }

    @discardableResult
    func disableCommandTabPair() -> Bool {
        guard originalStates.isEmpty else {
            BokslTabDiagnosticLog.write("native-hotkey.disable skipped; already active")
            return true
        }
        guard let symbols = loadSymbols() else { return false }

        var capturedStates: [NativeCommandTabSymbolicHotKey: Bool] = [:]
        for hotkey in NativeCommandTabSymbolicHotKey.allCases {
            capturedStates[hotkey] = symbols.isEnabled(hotkey.rawValue)
        }

        var disableSucceeded = true
        for hotkey in NativeCommandTabSymbolicHotKey.allCases {
            let result = symbols.setEnabled(hotkey.rawValue, false)
            BokslTabDiagnosticLog.write(
                "native-hotkey.disable id=\(hotkey.rawValue) previous=\(capturedStates[hotkey] ?? false) result=\(result)"
            )
            disableSucceeded = disableSucceeded && result == 0
        }

        guard disableSucceeded else {
            rollback(symbols: symbols, states: capturedStates)
            BokslTabDiagnosticLog.write("native-hotkey.disable failed; restored captured states")
            return false
        }

        originalStates = capturedStates
        return true
    }

    func restore() {
        guard !originalStates.isEmpty else { return }
        guard let symbols = loadSymbols() else {
            BokslTabDiagnosticLog.write("native-hotkey.restore failed; SkyLight symbols unavailable")
            originalStates.removeAll()
            return
        }

        for hotkey in NativeCommandTabSymbolicHotKey.allCases {
            guard let wasEnabled = originalStates[hotkey] else { continue }
            let result = symbols.setEnabled(hotkey.rawValue, wasEnabled)
            BokslTabDiagnosticLog.write(
                "native-hotkey.restore id=\(hotkey.rawValue) enabled=\(wasEnabled) result=\(result)"
            )
        }
        originalStates.removeAll()
    }

    private func rollback(symbols: SkyLightSymbolTable, states: [NativeCommandTabSymbolicHotKey: Bool]) {
        for hotkey in NativeCommandTabSymbolicHotKey.allCases {
            guard let wasEnabled = states[hotkey] else { continue }
            let result = symbols.setEnabled(hotkey.rawValue, wasEnabled)
            BokslTabDiagnosticLog.write(
                "native-hotkey.rollback id=\(hotkey.rawValue) enabled=\(wasEnabled) result=\(result)"
            )
        }
    }

    private func loadSymbols() -> SkyLightSymbolTable? {
        guard let symbols = loader.load() else {
            BokslTabDiagnosticLog.write("native-hotkey.symbols unavailable")
            return nil
        }
        return symbols
    }
}

struct SkyLightSymbolTable {
    let setEnabled: @convention(c) (Int, Bool) -> Int32
    let isEnabled: @convention(c) (Int) -> Bool
}

protocol SkyLightSymbolLoading {
    func load() -> SkyLightSymbolTable?
}

struct SkyLightSymbolLoader: SkyLightSymbolLoading {
    func load() -> SkyLightSymbolTable? {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            let error = dlerror().map { String(cString: $0) } ?? "unknown"
            BokslTabDiagnosticLog.write("native-hotkey.dlopen failed path=\(path) error=\(error)")
            return nil
        }

        guard let setSymbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled"),
              let isSymbol = dlsym(handle, "CGSIsSymbolicHotKeyEnabled")
        else {
            BokslTabDiagnosticLog.write("native-hotkey.dlsym failed CGSSetSymbolicHotKeyEnabled/CGSIsSymbolicHotKeyEnabled")
            return nil
        }

        let setEnabled = unsafeBitCast(setSymbol, to: SetSymbolicHotKeyEnabled.self)
        let isEnabled = unsafeBitCast(isSymbol, to: IsSymbolicHotKeyEnabled.self)
        return SkyLightSymbolTable(setEnabled: setEnabled, isEnabled: isEnabled)
    }
}
