import Foundation
@testable import mcs
import Testing

struct LockedTests {
    @Test("withLock returns the body's value and the mutation is visible to the next access")
    func returnsBodyValueAndPersistsMutation() {
        let locked = Locked(1)

        let doubled = locked.withLock { value -> Int in
            value *= 2
            return value
        }

        #expect(doubled == 2)
        #expect(locked.withLock { $0 } == 2)
    }

    @Test("A box captured by a closure is the same box the caller reads")
    func mutationThroughACaptureIsVisibleToTheOwner() {
        // The shape ScriptRunner relies on: a flag set inside a DispatchWorkItem and read back on
        // the calling thread after the work item has finished.
        let flag = Locked(false)
        let setter = { flag.withLock { $0 = true } }

        setter()

        #expect(flag.withLock { $0 })
    }
}
