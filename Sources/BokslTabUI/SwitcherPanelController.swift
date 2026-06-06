import AppKit
import BokslTabCore
import SwiftUI

@MainActor
public final class SwitcherPanelController {
    private let window: SwitcherPanelWindow
    private let iconProvider: (SwitcherItem) -> NSImage?
    private let onAction: (SwitcherKeyboardAction) -> Void
    private let onOpenSettings: () -> Void
    private var keyEventMonitor: Any?

    public init(
        iconProvider: @escaping (SwitcherItem) -> NSImage?,
        onKeyboardAction: @escaping (SwitcherKeyboardAction) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.iconProvider = iconProvider
        self.onAction = onKeyboardAction
        self.onOpenSettings = onOpenSettings
        self.window = SwitcherPanelWindow()
        self.window.onKeyboardAction = onKeyboardAction
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    public var isVisible: Bool {
        window.isVisible
    }

    public func show(state: SwitcherState, warning: String?) {
        update(state: state, warning: warning)
        positionNearCenter()
        installKeyEventMonitorIfNeeded()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func update(state: SwitcherState, warning: String?) {
        let frameBeforeUpdate = window.frame
        window.contentViewController = NSHostingController(
            rootView: SwitcherPanelView(
                mode: state.mode,
                items: state.items,
                selectedIndex: state.selectedIndex,
                warning: warning,
                iconProvider: iconProvider,
                onOpenSettings: onOpenSettings,
                onSelectIndex: { [weak self] index in self?.onAction(.select(index: index)) },
                onActivateIndex: { [weak self] index in self?.onAction(.activate(index: index)) }
            )
        )
        restoreFrameAfterContentUpdate(frameBeforeUpdate)
    }

    public func hide() {
        window.orderOut(nil)
        removeKeyEventMonitor()
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

    private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        guard window.isVisible else { return event }
        guard event.window == window || NSApp.keyWindow == window else { return event }
        guard let action = SwitcherKeyboardMapper.action(for: event) else { return event }
        onAction(action)
        return nil
    }

    private func restoreFrameAfterContentUpdate(_ frameBeforeUpdate: NSRect) {
        guard window.isVisible else { return }
        window.setFrame(frameBeforeUpdate, display: true)
    }

    private func positionNearCenter() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let fittingHeight = window.contentViewController?.view.fittingSize.height ?? 320
        let size = NSSize(width: 560, height: max(220, fittingHeight))
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY + min(80, screenFrame.height * 0.12) - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private final class SwitcherPanelWindow: NSPanel {
    var onKeyboardAction: ((SwitcherKeyboardAction) -> Void)?

    init() {
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let action = SwitcherKeyboardMapper.action(for: event) else {
            super.keyDown(with: event)
            return
        }
        onKeyboardAction?(action)
    }
}

enum SwitcherKeyboardMapper {
    static func action(for event: NSEvent) -> SwitcherKeyboardAction? {
        if event.type == .flagsChanged {
            guard event.keyCode == 58 || event.keyCode == 61 else { return nil }
            return event.modifierFlags.contains(.option) ? nil : .modifierReleased
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
