import AppKit
import BokslTabCore
import SwiftUI

@MainActor
public final class SwitcherPanelController {
    private let iconProvider: (SwitcherItem) -> NSImage?
    private let onAction: (SwitcherKeyboardAction) -> Void
    private let onOpenSettings: () -> Void
    private let diagnosticLog: (String) -> Void
    private let currentModifierFlags: () -> NSEvent.ModifierFlags
    private var panels: [SwitcherPanelWindow] = []
    private var panelScreens: [NSScreen] = []
    private var keyEventMonitor: Any?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var modifierReleaseFallbackTimer: Timer?
    private var isHidingProgrammatically = false
    private var triggerModifier: SwitcherTriggerModifier = .option

    public init(
        iconProvider: @escaping (SwitcherItem) -> NSImage?,
        onKeyboardAction: @escaping (SwitcherKeyboardAction) -> Void,
        onOpenSettings: @escaping () -> Void,
        diagnosticLog: @escaping (String) -> Void = { _ in },
        currentModifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    ) {
        self.iconProvider = iconProvider
        self.onAction = onKeyboardAction
        self.onOpenSettings = onOpenSettings
        self.diagnosticLog = diagnosticLog
        self.currentModifierFlags = currentModifierFlags
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
        }
        modifierReleaseFallbackTimer?.invalidate()
    }

    public var isVisible: Bool {
        panels.contains { $0.isVisible }
    }

    public func show(state: SwitcherState, warning: String?) {
        diagnosticLog(
            "panel.show begin mode=\(state.mode.rawValue) items=\(state.items.count) selectedIndex=\(state.selectedIndex) visibleBefore=\(isVisible)"
        )
        configurePanelsForCurrentScreens()
        update(state: state, warning: warning)
        positionPanels(state: state, warning: warning)
        installKeyEventMonitorIfNeeded()
        installAppDidResignActiveObserverIfNeeded()
        startModifierReleaseFallbackIfNeeded()

        guard let primaryPanel else { return }
        for panel in mirrorPanels {
            panel.orderFront(nil)
        }
        primaryPanel.makeKeyAndOrderFront(nil)
        primaryPanel.makeFirstResponder(primaryPanel)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        diagnosticLog(
            "panel.show ready mode=\(state.mode.rawValue) trigger=\(triggerModifier.diagnosticDescription) keyWindow=\(NSApp.keyWindow == primaryPanel) mainWindow=\(NSApp.mainWindow == primaryPanel) monitorInstalled=\(keyEventMonitor != nil)"
        )
    }

    public func update(state: SwitcherState, warning: String?) {
        if panels.isEmpty {
            configurePanelsForCurrentScreens()
        }
        triggerModifier = state.mode.triggerModifier
        let framesBeforeUpdate = panels.map(\.frame)

        for (index, panel) in panels.enumerated() {
            let screen = panelScreens[safe: index] ?? NSScreen.main
            let availableSize = screen?.visibleFrame.size ?? SwitcherPanelLayout.defaultAvailableSize
            panel.contentViewController = NSHostingController(
                rootView: SwitcherPanelView(
                    items: state.items,
                    selectedIndex: state.selectedIndex,
                    warning: warning,
                    availableSize: availableSize,
                    iconProvider: iconProvider,
                    onOpenSettings: onOpenSettings,
                    onSelectIndex: { [weak self] index in self?.onAction(.select(index: index)) },
                    onActivateIndex: { [weak self] index in self?.onAction(.activate(index: index)) }
                )
            )
        }

        restoreFramesAfterContentUpdate(framesBeforeUpdate)
    }

    public func hide() {
        diagnosticLog("panel.hide begin visible=\(isVisible)")
        isHidingProgrammatically = true
        for panel in panels {
            panel.orderOut(nil)
        }
        isHidingProgrammatically = false
        stopModifierReleaseFallback(reason: "panel-hidden")
        removeKeyEventMonitor()
        removeAppDidResignActiveObserver()
        diagnosticLog("panel.hide end visible=\(isVisible)")
    }

    private var primaryPanel: SwitcherPanelWindow? {
        panels.first
    }

    private var mirrorPanels: Array<SwitcherPanelWindow>.SubSequence {
        panels.dropFirst()
    }

    private func configurePanelsForCurrentScreens() {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        guard !screens.isEmpty else { return }

        let wasHidingProgrammatically = isHidingProgrammatically
        isHidingProgrammatically = true
        defer { isHidingProgrammatically = wasHidingProgrammatically }

        for panel in panels where panel.isVisible {
            panel.orderOut(nil)
        }

        panels = screens.enumerated().map { index, _ in
            let panel = SwitcherPanelWindow(allowsKeyFocus: index == 0)
            panel.onKeyboardAction = { [weak self] action in self?.onAction(action) }
            if index == 0 {
                panel.onFocusLost = { [weak self] in self?.handleFocusLost() }
            }
            return panel
        }
        panelScreens = screens
    }

    private func installKeyEventMonitorIfNeeded() {
        guard keyEventMonitor == nil else {
            diagnosticLog("panel.monitor install skipped reason=already-installed")
            return
        }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredEvent(event)
        }
        diagnosticLog("panel.monitor installed events=keyDown+flagsChanged")
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
            diagnosticLog("panel.monitor removed")
        }
    }

    private func installAppDidResignActiveObserverIfNeeded() {
        guard appDidResignActiveObserver == nil else {
            diagnosticLog("panel.focus observer install skipped reason=already-installed")
            return
        }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleFocusLost()
            }
        }
        diagnosticLog("panel.focus observer installed")
    }

    private func removeAppDidResignActiveObserver() {
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
            self.appDidResignActiveObserver = nil
            diagnosticLog("panel.focus observer removed")
        }
    }

    private func startModifierReleaseFallbackIfNeeded() {
        guard modifierReleaseFallbackTimer == nil else {
            diagnosticLog("panel.releaseFallback start skipped reason=already-running")
            return
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkModifierReleaseFallback()
            }
        }
        modifierReleaseFallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        diagnosticLog("panel.releaseFallback started interval=0.05")
    }

    private func stopModifierReleaseFallback(reason: String) {
        guard let modifierReleaseFallbackTimer else { return }
        modifierReleaseFallbackTimer.invalidate()
        self.modifierReleaseFallbackTimer = nil
        diagnosticLog("panel.releaseFallback stopped reason=\(reason)")
    }

    private func checkModifierReleaseFallback() {
        guard isVisible else {
            stopModifierReleaseFallback(reason: "not-visible")
            return
        }

        let flags = currentModifierFlags()
        guard let action = triggerModifier.modifierReleaseFallbackAction(currentFlags: flags) else { return }

        diagnosticLog(
            "panel.releaseFallback action=\(action.diagnosticDescription) flags=\(flags.bokslTabDiagnosticDescription) trigger=\(triggerModifier.diagnosticDescription)"
        )
        onAction(action)
    }

    private func handleFocusLost() {
        guard isVisible, !isHidingProgrammatically else { return }
        diagnosticLog("panel.focusLost visible=\(isVisible) hidingProgrammatically=\(isHidingProgrammatically)")
        onAction(.focusLost)
    }

    private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        let eventDescription = event.bokslTabDiagnosticDescription(triggerModifier: triggerModifier)
        guard let primaryPanel, primaryPanel.isVisible else {
            diagnosticLog("panel.event ignored reason=no-visible-primary \(eventDescription)")
            return event
        }
        let isPanelEvent = event.window == primaryPanel || NSApp.keyWindow == primaryPanel
        guard isPanelEvent else {
            diagnosticLog(
                "panel.event ignored reason=window-mismatch \(eventDescription) eventWindowIsPrimary=\(event.window == primaryPanel) keyWindowIsPrimary=\(NSApp.keyWindow == primaryPanel)"
            )
            return event
        }
        guard let action = SwitcherKeyboardMapper.action(for: event, triggerModifier: triggerModifier) else {
            diagnosticLog("panel.event ignored reason=no-action \(eventDescription)")
            return event
        }
        diagnosticLog("panel.event action=\(action.diagnosticDescription) \(eventDescription)")
        onAction(action)
        return nil
    }

    private func restoreFramesAfterContentUpdate(_ framesBeforeUpdate: [NSRect]) {
        guard isVisible else { return }
        for (index, frame) in framesBeforeUpdate.enumerated() where panels.indices.contains(index) {
            panels[index].setFrame(frame, display: true)
        }
    }

    private func positionPanels(state: SwitcherState, warning: String?) {
        for (index, panel) in panels.enumerated() {
            guard let screen = panelScreens[safe: index] else { continue }
            position(panel: panel, on: screen, itemCount: state.items.count, warning: warning)
        }
    }

    private func position(panel: SwitcherPanelWindow, on screen: NSScreen, itemCount: Int, warning: String?) {
        let frame = SwitcherPanelLayout.panelFrame(
            itemCount: itemCount,
            warning: warning,
            visibleFrame: screen.visibleFrame,
            fittingSize: panel.contentViewController?.view.fittingSize ?? .zero
        )
        panel.setFrame(frame, display: true)
    }
}

private final class SwitcherPanelWindow: NSPanel, NSWindowDelegate {
    var onKeyboardAction: ((SwitcherKeyboardAction) -> Void)?
    var onFocusLost: (() -> Void)?
    private let allowsKeyFocus: Bool

    init(allowsKeyFocus: Bool) {
        self.allowsKeyFocus = allowsKeyFocus
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = !allowsKeyFocus
        delegate = self
    }

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { allowsKeyFocus }

    func windowDidResignKey(_ notification: Notification) {
        guard allowsKeyFocus, isVisible else { return }
        onFocusLost?()
    }

    override func keyDown(with event: NSEvent) {
        guard let action = SwitcherKeyboardMapper.action(for: event) else {
            super.keyDown(with: event)
            return
        }
        onKeyboardAction?(action)
    }
}

enum SwitcherTriggerModifier: Equatable, Sendable {
    case option
    case command

    func isRelevantFlagsChangedEvent(_ event: NSEvent) -> Bool {
        switch self {
        case .option:
            return event.keyCode == 58 || event.keyCode == 61
        case .command:
            return event.keyCode == 55 || event.keyCode == 54
        }
    }

    func isStillPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .option:
            return flags.contains(.option)
        case .command:
            return flags.contains(.command)
        }
    }

    func modifierReleaseFallbackAction(currentFlags: NSEvent.ModifierFlags) -> SwitcherKeyboardAction? {
        isStillPressed(in: currentFlags) ? nil : .modifierReleased
    }
}

private extension SwitcherTriggerModifier {
    var diagnosticDescription: String {
        switch self {
        case .option:
            return "option"
        case .command:
            return "command"
        }
    }
}

enum SwitcherKeyboardMapper {
    static func action(
        for event: NSEvent,
        triggerModifier: SwitcherTriggerModifier = .option
    ) -> SwitcherKeyboardAction? {
        if event.type == .flagsChanged {
            if triggerModifier.isStillPressed(in: event.modifierFlags),
               event.isShiftPressEvent {
                return .previous
            }
            guard triggerModifier.isRelevantFlagsChangedEvent(event) else { return nil }
            return triggerModifier.isStillPressed(in: event.modifierFlags) ? nil : .modifierReleased
        }

        switch event.keyCode {
        case 48: // Tab
            return event.modifierFlags.contains(.shift) ? .previous : .next
        case 124, 125: // Right, Down
            return .next
        case 123, 126: // Left, Up
            return .previous
        case 36, 76, 49: // Return, keypad Enter, Space
            return .confirm
        case 53: // Escape
            return .cancel
        default:
            return nil
        }
    }
}

private extension SwitcherKeyboardAction {
    var diagnosticDescription: String {
        switch self {
        case .next:
            return "next"
        case .previous:
            return "previous"
        case .confirm:
            return "confirm"
        case .cancel:
            return "cancel"
        case .modifierReleased:
            return "modifierReleased"
        case .focusLost:
            return "focusLost"
        case .select(let index):
            return "select(\(index))"
        case .activate(let index):
            return "activate(\(index))"
        }
    }
}

private extension NSEvent {
    var isShiftPressEvent: Bool {
        (keyCode == 56 || keyCode == 60) && modifierFlags.contains(.shift)
    }

    func bokslTabDiagnosticDescription(triggerModifier: SwitcherTriggerModifier) -> String {
        "type=\(type.bokslTabDiagnosticDescription) keyCode=\(keyCode) flags=\(modifierFlags.bokslTabDiagnosticDescription) trigger=\(triggerModifier.diagnosticDescription) triggerPressed=\(triggerModifier.isStillPressed(in: modifierFlags)) shiftPress=\(isShiftPressEvent)"
    }
}

private extension NSEvent.EventType {
    var bokslTabDiagnosticDescription: String {
        switch self {
        case .keyDown:
            return "keyDown"
        case .keyUp:
            return "keyUp"
        case .flagsChanged:
            return "flagsChanged"
        default:
            return "type(\(rawValue))"
        }
    }
}

private extension NSEvent.ModifierFlags {
    var bokslTabDiagnosticDescription: String {
        var parts: [String] = []
        if contains(.command) { parts.append("command") }
        if contains(.option) { parts.append("option") }
        if contains(.control) { parts.append("control") }
        if contains(.shift) { parts.append("shift") }
        if contains(.function) { parts.append("fn") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}

private extension SwitcherMode {
    var triggerModifier: SwitcherTriggerModifier {
        SwitcherTriggerModifier(modifiers: defaultHotkeyDefinition.modifiers)
    }
}

private extension SwitcherTriggerModifier {
    init(modifiers: HotkeyModifiers) {
        self = modifiers.contains(.command) ? .command : .option
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
