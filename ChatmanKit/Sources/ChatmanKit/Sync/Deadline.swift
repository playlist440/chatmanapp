import Foundation

/// Runs `operation`, but gives up after `seconds` whatever the operation does.
///
/// A request with a timeout ought never to need this, and one did: a question to the WhatsApp
/// bridge, asked just before the phone was put away, never came back — not with an answer, not
/// with an error. Everything waiting on it waited for good: the round of questions it belonged
/// to never ended, and from then on WhatsApp was "not asked yet" and missing from the
/// settings until the app was closed.
///
/// The operation runs in a task of its own and is not waited for once the time is up — not
/// even to be cancelled. Cancelling something that ignores cancellation is how it got stuck.
func withDeadline<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = Once<Result<T, any Error>>()
    return try await withCheckedThrowingContinuation { continuation in
        once.set(continuation)
        let work = Task {
            do { once.resume(.success(try await operation())) }
            catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            once.resume(.failure(DeadlinePassed()))
        }
    }
}

struct DeadlinePassed: Error {}

/// A continuation resumed by whichever of two tasks gets there first, and only by that one.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var typed: ((Value) -> Void)?

    func set<T>(_ continuation: CheckedContinuation<T, any Error>) where Value == Result<T, any Error> {
        lock.withLock {
            typed = { result in continuation.resume(with: result) }
        }
    }

    func resume(_ value: Value) {
        let action: ((Value) -> Void)? = lock.withLock {
            defer { typed = nil }
            return typed
        }
        action?(value)
    }
}
