import Foundation

/// Every transition invalidates the previous deadline, even hide → show → hide.
@MainActor
final class DelayedHide {
    private var generation = UUID()
    private var work: DispatchWorkItem?

    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
    }

    func schedule(after delay: TimeInterval = 0.3, _ action: @escaping () -> Void) {
        cancel()
        let token = generation
        let next = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.work = nil
            action()
        }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
    }
}
