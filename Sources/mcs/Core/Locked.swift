import Foundation

/// A mutable value guarded by a lock. `OSAllocatedUnfairLock` is Darwin-only and
/// `Synchronization.Mutex` needs macOS 15, above the macOS 13 floor. `@unchecked` because every
/// access to `value` goes through `lock`, which the compiler cannot verify.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
