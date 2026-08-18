import Foundation

public final class ForegroundInterferenceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGate: InputCancellationGate?
    private var inputEmissionActive = false

    public init() {}

    public func begin(_ gate: InputCancellationGate) {
        lock.lock()
        activeGate = gate
        inputEmissionActive = false
        lock.unlock()
    }

    public func end(_ gate: InputCancellationGate) {
        lock.lock()
        if activeGate === gate {
            activeGate = nil
            inputEmissionActive = false
        }
        lock.unlock()
    }

    public func beginInputEmission(_ gate: InputCancellationGate) {
        lock.lock()
        if activeGate === gate { inputEmissionActive = true }
        lock.unlock()
    }

    public func endInputEmission(_ gate: InputCancellationGate) {
        lock.lock()
        if activeGate === gate { inputEmissionActive = false }
        lock.unlock()
    }

    public func hasActiveLease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGate != nil
    }

    public func hasActiveInputEmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGate != nil && inputEmissionActive
    }

    @discardableResult
    public func invalidateActive(reason: String) -> Bool {
        lock.lock()
        let gate = activeGate
        lock.unlock()
        gate?.invalidate(reason: reason)
        return gate != nil
    }
}
