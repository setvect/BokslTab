import Foundation

public enum SwitcherKeyboardAction: Equatable, Sendable {
    case next
    case previous
    case confirm
    case cancel
    case select(index: Int)
    case activate(index: Int)
}
