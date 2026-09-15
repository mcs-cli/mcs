import Foundation

/// A mutable value guarded by a lock, with the `withLock { $0 }` shape of `OSAllocatedUnfairLock`,
/// which is Darwin-only. `Synchronization.Mutex` would be the modern answer but is macOS 15+, above
/// this package's macOS 13 deployment target.
///
/// `@unchecked Sendable` is the point of the type rather than a way to quiet the checker: the
/// invariant — every access to `value` happens under `lock` — is real and cannot be expressed to
/// the compiler.
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
