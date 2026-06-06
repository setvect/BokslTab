import AppKit
import BokslTabCore
import SwiftUI

@MainActor
public final class SwitcherPanelController {
    private let iconProvider: (SwitcherItem) -> NSImage?
    private let onAction: (SwitcherKeyboardAction) -> Void
    private let onOpenSettings: () -> Void
    private var panels: [SwitcherPanelWindow] = []
    private var panelScreens: [NSScreen] = []
    private var keyEventMonitor: Any?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var isHidingProgrammatically = false
    private var triggerModifier: SwitcherTriggerModifier = .option

    public init(
        iconProvider: @escaping (SwitcherItem) -> NSImage?,
        onKeyboardAction: @escaping (SwitcherKeyboardAction) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.iconProvider = iconProvider
        self.onAction = onKeyboardAction
        self.onOpenSettings = onOpenSettings
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
        }
    }

    public var isVisible: Bool {
        panels.contains { $0.isVisible }
    }

    public func show(state: SwitcherState, warning: String?) {
        configurePanelsForCurrentScreens()
        update(state: state, warning: warning)
        positionPanels(state: state, warning: warning)
        installKeyEventMonitorIfNeeded()
        installAppDidResignActiveObserverIfNeeded()

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
        isHidingProgrammatically = true
        for panel in panels {
            panel.orderOut(nil)
        }
        isHidingProgrammatically = false
        removeKeyEventMonitor()
        removeAppDidResignActiveObserver()
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
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredEvent(event)
        }
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func installAppDidResignActiveObserverIfNeeded() {
        guard appDidResignActiveObserver == nil else { return }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleFocusLost()
            }
        }
    }

    private func removeAppDidResignActiveObserver() {
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
            self.appDidResignActiveObserver = nil
        }
    }

    private func handleFocusLost() {
        guard isVisible, !isHidingProgrammatically else { return }
        onAction(.focusLost)
    }

    private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        guard let primaryPanel, primaryPanel.isVisible else { return event }
        guard event.window == primaryPanel || NSApp.keyWindow == primaryPanel else { return event }
        guard let action = SwitcherKeyboardMapper.action(for: event, triggerModifier: triggerModifier) else { return event }
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
}

enum SwitcherKeyboardMapper {
    static func action(
        for event: NSEvent,
        triggerModifier: SwitcherTriggerModifier = .option
    ) -> SwitcherKeyboardAction? {
        if event.type == .flagsChanged {
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
