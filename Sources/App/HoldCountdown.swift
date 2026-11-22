import Foundation

/// The "hold to end" countdown, kept apart from the button's looks so it can't be reset by
/// the screen redrawing, and so it can be tested.
@MainActor
final class HoldCountdown: ObservableObject {
    let seconds: Int
    /// Seconds left while held (3, 2, 1); nil when not held.
    @Published private(set) var remaining: Int?
    /// Bumped each time a hold runs all the way (for the success buzz).
    @Published private(set) var completions = 0
    /// Runs when a hold completes.
    var onComplete: (() -> Void)?

    private var task: Task<Void, Never>?
    private let sleep: (UInt64) async -> Void

    init(seconds: Int = 3,
         sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        self.seconds = max(1, seconds)
        self.sleep = sleep
    }

    var isHolding: Bool { remaining != nil }

    /// Finger down: start counting.
    func press() {
        guard task == nil else { return }
        remaining = seconds
        let total = seconds
        task = Task { @MainActor [weak self] in
            for left in stride(from: total - 1, through: 0, by: -1) {
                guard let self else { return }
                await self.sleep(1_000_000_000)
                if Task.isCancelled { return }
                if left == 0 {
                    self.task = nil
                    self.remaining = nil
                    self.completions += 1
                    self.onComplete?()
                    return
                }
                self.remaining = left
            }
        }
    }

    /// Finger up (or the touch was interrupted): stop, nothing happens.
    func release() {
        task?.cancel()
        task = nil
        remaining = nil
    }

    /// Tests: wait for the running countdown to finish or stop.
    func settle() async {
        await task?.value
    }
}
