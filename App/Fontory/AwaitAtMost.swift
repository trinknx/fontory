import Foundation

/// Waits for `work` to finish, but no longer than `budget`. Returns true when the work finished in time.
/// `work` is not cancelled when the budget runs out; it keeps going on its own (e.g. a write finishing while the app
/// exits). Unlike a task group, this returns as soon as either side is done.
@discardableResult
func awaitAtMost(_ budget: Duration, _ work: Task<Void, Never>) async -> Bool {
    let race = ResumeOnce()
    let finished = Task { await work.value; race.resume(true) }
    let timer = Task { try? await Task.sleep(for: budget); race.resume(false) }
    let inTime = await withCheckedContinuation { race.set($0) }
    timer.cancel()
    _ = finished
    return inTime
}

/// Resumes a continuation exactly once, whichever side gets there first (also before the continuation is set).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func set(_ c: CheckedContinuation<Bool, Never>) {
        let ready: Bool? = lock.withLock {
            if let result { return result }
            continuation = c
            return nil
        }
        if let ready { c.resume(returning: ready) }
    }

    func resume(_ value: Bool) {
        let c: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
