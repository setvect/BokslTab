import BokslTabCore
import Foundation

struct PrioritizedHotkeyPlan: Equatable, Sendable {
    let eventTapDefinition: HotkeyDefinition?
    let carbonDefinitionsWhenEventTapSucceeds: [HotkeyDefinition]

    static func make(definitions: [HotkeyDefinition]) -> PrioritizedHotkeyPlan {
        let eventTapDefinition = definitions.first { definition in
            definition.mode == .activeAppWindows
                && definition.keyCode == 48
                && definition.modifiers == [.command]
        }
        let carbonDefinitionsWhenEventTapSucceeds = definitions.filter { $0 != eventTapDefinition }
        return PrioritizedHotkeyPlan(
            eventTapDefinition: eventTapDefinition,
            carbonDefinitionsWhenEventTapSucceeds: carbonDefinitionsWhenEventTapSucceeds
        )
    }
}

public final class PrioritizedGlobalHotkeyService: GlobalHotkeyServicing {
    private let commandTabEventTapService: CommandTabEventTapHotkeyServicing
    private let fallbackHotkeyService: GlobalHotkeyServicing

    public init(
        commandTabEventTapService: CommandTabEventTapHotkeyServicing = CommandTabEventTapHotkeyService(),
        fallbackHotkeyService: GlobalHotkeyServicing = CarbonGlobalHotkeyService()
    ) {
        self.commandTabEventTapService = commandTabEventTapService
        self.fallbackHotkeyService = fallbackHotkeyService
    }

    public func start(
        definitions: [HotkeyDefinition],
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) throws {
        stop()

        let plan = PrioritizedHotkeyPlan.make(definitions: definitions)
        let carbonDefinitions: [HotkeyDefinition]

        BokslTabDiagnosticLog.write("hotkey.priority.start definitions=\(definitions.map(\.description).joined(separator: ", "))")
        if let eventTapDefinition = plan.eventTapDefinition,
           startCommandTabEventTap(definition: eventTapDefinition, onTrigger: onTrigger) {
            carbonDefinitions = plan.carbonDefinitionsWhenEventTapSucceeds
            BokslTabDiagnosticLog.write("hotkey.priority.eventtap active; carbonDefinitions=\(carbonDefinitions.map(\.description).joined(separator: ", "))")
        } else {
            carbonDefinitions = definitions
            BokslTabDiagnosticLog.write("hotkey.priority.eventtap unavailable; falling back to Carbon for all definitions")
        }

        do {
            try fallbackHotkeyService.start(definitions: carbonDefinitions, onTrigger: onTrigger)
            BokslTabDiagnosticLog.write("hotkey.priority.carbon start succeeded definitions=\(carbonDefinitions.map(\.description).joined(separator: ", "))")
        } catch {
            BokslTabDiagnosticLog.write("hotkey.priority.carbon start failed error=\(error)")
            stop()
            throw error
        }
    }

    public func stop() {
        commandTabEventTapService.stop()
        fallbackHotkeyService.stop()
    }

    private func startCommandTabEventTap(
        definition: HotkeyDefinition,
        onTrigger: @escaping @Sendable (SwitcherMode) -> Void
    ) -> Bool {
        do {
            try commandTabEventTapService.start(definition: definition, onTrigger: onTrigger)
            BokslTabDiagnosticLog.write("hotkey.priority.eventtap start succeeded definition=\(definition)")
            return true
        } catch {
            BokslTabDiagnosticLog.write("hotkey.priority.eventtap start failed error=\(error)")
            commandTabEventTapService.stop()
            return false
        }
    }
}
