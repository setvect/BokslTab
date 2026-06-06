import AppKit
import BokslTabCore
import SwiftUI

@MainActor
public final class SwitcherPanelController {
    private let window: SwitcherPanelWindow
    private let iconProvider: (SwitcherItem) -> NSImage?

    public init(
        iconProvider: @escaping (SwitcherItem) -> NSImage?,
        onKeyboardAction: @escaping (SwitcherKeyboardAction) -> Void
    ) {
        self.iconProvider = iconProvider
        self.window = SwitcherPanelWindow()
        self.window.onKeyboardAction = onKeyboardAction
    }

    public var isVisible: Bool {
        window.isVisible
    }

    public func show(state: SwitcherState, warning: String?) {
        update(state: state, warning: warning)
        positionNearCenter()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func update(state: SwitcherState, warning: String?) {
        window.contentViewController = NSHostingController(
            rootView: SwitcherPanelView(
                mode: state.mode,
                items: state.items,
                selectedIndex: state.selectedIndex,
                warning: warning,
                iconProvider: iconProvider
            )
        )
    }

    public func hide() {
        window.orderOut(nil)
    }

    private func positionNearCenter() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let size = NSSize(width: 560, height: window.contentViewController?.view.fittingSize.height ?? 320)
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
