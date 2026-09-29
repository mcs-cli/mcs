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
}
