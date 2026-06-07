import BokslTabCore
import CoreGraphics
import Foundation

enum CommandTabEventTapMatcher {
    static let tabKeyCode: Int64 = 48

    static func shouldCapture(
        keyCode: Int64,
        flags: CGEventFlags,
        definition: HotkeyDefinition
    ) -> Bool {
        definition.keyCode == UInt32(tabKeyCode)
            && definition.modifiers == [.command]
            && keyCode == tabKeyCode
            && flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskControl)
    }
}

private enum CommandTabEventTapStatus {
    static let creationFailed = OSStatus(-10_001)
    static let runLoopSourceFailed = OSStatus(-10_002)
}

enum CommandTabEventTapConfiguration {
    static let location = CGEventTapLocation.cghidEventTap
    static let locationDescription = "cghidEventTap"
}

public protocol CommandTabEventTapHotkeyServicing: AnyObject {
    func start(
        definition: HotkeyDefinition,
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) throws
    func stop()
}

public final class CommandTabEventTapHotkeyService: CommandTabEventTapHotkeyServicing {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var definition: HotkeyDefinition?
    private var onTrigger: (@Sendable (SwitcherMode) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        definition: HotkeyDefinition,
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) throws {
        stop()

        BokslTabDiagnosticLog.write(
            "eventtap.start requested location=\(CommandTabEventTapConfiguration.locationDescription) definition=\(definition)"
        )

        guard definition.keyCode == UInt32(CommandTabEventTapMatcher.tabKeyCode),
              definition.modifiers == [.command]
        else {
            BokslTabDiagnosticLog.write("eventtap.start rejected invalid definition=\(definition)")
            throw HotkeyRegistrationError.registrationFailed(definition: definition, code: OSStatus(paramErr))
        }

        self.definition = definition
        self.onTrigger = onTrigger

        let eventsOfInterest = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: CommandTabEventTapConfiguration.location,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: CommandTabEventTapHotkeyService.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            BokslTabDiagnosticLog.write(
                "eventtap.start failed tapCreate location=\(CommandTabEventTapConfiguration.locationDescription) code=\(CommandTabEventTapStatus.creationFailed) definition=\(definition)"
            )
            stop()
            throw HotkeyRegistrationError.registrationFailed(
                definition: definition,
                code: CommandTabEventTapStatus.creationFailed
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            BokslTabDiagnosticLog.write("eventtap.start failed runLoopSource code=\(CommandTabEventTapStatus.runLoopSourceFailed) definition=\(definition)")
            CFMachPortInvalidate(tap)
            stop()
            throw HotkeyRegistrationError.registrationFailed(
                definition: definition,
                code: CommandTabEventTapStatus.runLoopSourceFailed
            )
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        BokslTabDiagnosticLog.write(
            "eventtap.start succeeded location=\(CommandTabEventTapConfiguration.locationDescription) definition=\(definition) runLoop=main commonModes"
        )
    }

    public func stop() {
        if eventTap != nil || runLoopSource != nil {
            BokslTabDiagnosticLog.write("eventtap.stop")
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        definition = nil
        onTrigger = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            BokslTabDiagnosticLog.write("eventtap.disabled type=\(type.rawValue); re-enable requested")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        guard type == .keyDown, let definition else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isDiagnosticCandidate = keyCode == CommandTabEventTapMatcher.tabKeyCode || flags.contains(.maskCommand)
        let shouldCapture = CommandTabEventTapMatcher.shouldCapture(
            keyCode: keyCode,
            flags: flags,
            definition: definition
        )
        if isDiagnosticCandidate {
            BokslTabDiagnosticLog.write(
                "eventtap.keyDown keyCode=\(keyCode) flags=\(flags.bokslTabDiagnosticDescription) shouldCapture=\(shouldCapture)"
            )
        }
        guard shouldCapture else { return false }

        BokslTabDiagnosticLog.write("eventtap.trigger mode=\(definition.mode.rawValue); suppressing macOS propagation")
        onTrigger?(definition.mode)
        return true
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<CommandTabEventTapHotkeyService>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return service.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }
}


private extension CGEventFlags {
    var bokslTabDiagnosticDescription: String {
        var parts: [String] = []
        if contains(.maskCommand) { parts.append("command") }
        if contains(.maskAlternate) { parts.append("option") }
        if contains(.maskControl) { parts.append("control") }
        if contains(.maskShift) { parts.append("shift") }
        if contains(.maskSecondaryFn) { parts.append("fn") }
        let names = parts.isEmpty ? "none" : parts.joined(separator: "+")
        return "\(names) raw=0x\(String(rawValue, radix: 16))"
    }
}
