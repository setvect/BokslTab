import BokslTabCore
import Carbon
import Foundation

public final class CarbonGlobalHotkeyService: GlobalHotkeyServicing {
    private let signature: OSType = 0x424F4B53 // "BOKS"
    private var eventHandler: EventHandlerRef?
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var modeByHotkeyID: [UInt32: SwitcherMode] = [:]
    private var onTrigger: (@Sendable (SwitcherMode) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    public func start(definitions: [HotkeyDefinition], onTrigger: @escaping @Sendable (SwitcherMode) -> Void) throws {
        BokslTabDiagnosticLog.write("carbon.start requested definitions=\(definitions.map(\.description).joined(separator: ", "))")
        stop()
        self.onTrigger = onTrigger

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            CarbonGlobalHotkeyService.hotkeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            BokslTabDiagnosticLog.write("carbon.start failed InstallEventHandler code=\(installStatus)")
            throw HotkeyRegistrationError.handlerInstallFailed(code: installStatus)
        }

        var failures: [HotkeyRegistrationFailure] = []

        for (index, definition) in definitions.enumerated() {
            var hotkeyRef: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                definition.keyCode,
                definition.modifiers.carbonFlags,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )

            guard status == noErr, let registeredRef = hotkeyRef else {
                BokslTabDiagnosticLog.write("carbon.register failed id=\(hotkeyID.id) definition=\(definition) code=\(status)")
                failures.append(HotkeyRegistrationFailure(definition: definition, code: status))
                continue
            }

            BokslTabDiagnosticLog.write("carbon.register succeeded id=\(hotkeyID.id) definition=\(definition)")
            hotkeyRefs.append(registeredRef)
            modeByHotkeyID[hotkeyID.id] = definition.mode
        }

        if !failures.isEmpty {
            if hotkeyRefs.isEmpty {
                BokslTabDiagnosticLog.write("carbon.start failed all registrations failures=\(failures)")
                stop()
                if failures.count == 1, let failure = failures.first {
                    throw HotkeyRegistrationError.registrationFailed(definition: failure.definition, code: failure.code)
                }
            }
            BokslTabDiagnosticLog.write("carbon.start partialRegistrationFailed failures=\(failures)")
            throw HotkeyRegistrationError.partialRegistrationFailed(failures: failures)
        }

        BokslTabDiagnosticLog.write("carbon.start succeeded count=\(hotkeyRefs.count)")
    }

    public func stop() {
        if !hotkeyRefs.isEmpty || eventHandler != nil {
            BokslTabDiagnosticLog.write("carbon.stop registeredCount=\(hotkeyRefs.count)")
        }
        for hotkeyRef in hotkeyRefs {
            UnregisterEventHotKey(hotkeyRef)
        }
        hotkeyRefs.removeAll()
        modeByHotkeyID.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        onTrigger = nil
    }

    private func handle(hotkeyID: EventHotKeyID) -> OSStatus {
        guard hotkeyID.signature == signature,
              let mode = modeByHotkeyID[hotkeyID.id]
        else {
            BokslTabDiagnosticLog.write("carbon.hotkey ignored signature=\(hotkeyID.signature) id=\(hotkeyID.id)")
            return OSStatus(eventNotHandledErr)
        }

        BokslTabDiagnosticLog.write("carbon.hotkey trigger id=\(hotkeyID.id) mode=\(mode.rawValue)")
        onTrigger?(mode)
        return noErr
    }

    private static let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )
        guard status == noErr else { return status }

        let service = Unmanaged<CarbonGlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
        return service.handle(hotkeyID: hotkeyID)
    }
}

public extension HotkeyModifiers {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
