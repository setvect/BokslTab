import Foundation

enum SwitcherKeyRepeatTiming {
    static let initialDelay: TimeInterval = 0.2
    static let repeatInterval: TimeInterval = 0.1
}

@MainActor
final class SwitcherKeyHoldRepeater {
    private let initialDelay: TimeInterval
    private let repeatInterval: TimeInterval
    private let isHeld: () -> Bool
    private let onRepeat: () -> Void
    private var repeatTask: Task<Void, Never>?

    init(
        initialDelay: TimeInterval,
        repeatInterval: TimeInterval,
        isHeld: @escaping () -> Bool,
        onRepeat: @escaping () -> Void
    ) {
        self.initialDelay = initialDelay
        self.repeatInterval = repeatInterval
        self.isHeld = isHeld
        self.onRepeat = onRepeat
    }

    func restart() {
        stop()
        repeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: initialDelay.nanoseconds)
                while isHeld() {
                    onRepeat()
                    try await Task.sleep(nanoseconds: repeatInterval.nanoseconds)
                }
            } catch is CancellationError {
                // A new key press or panel dismissal replaced this repeat cycle.
            } catch {
                assertionFailure("Unexpected hold-repeat sleep failure: \(error)")
            }
        }
    }

    func stop() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

private extension TimeInterval {
    var nanoseconds: UInt64 {
        UInt64(max(self, 0) * 1_000_000_000)
    }
}
