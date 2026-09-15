import Foundation
@testable import mcs
import Testing

struct CLIOutputTests {
    private func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    @Test("readByte returns the byte that was written")
    func readByteReturnsWrittenByte() {
        let (readEnd, writeEnd) = makePipe()
        defer { close(readEnd) }

        var byte: UInt8 = 0x6A
        #expect(write(writeEnd, &byte, 1) == 1)
        close(writeEnd)

        #expect(CLIOutput(colorsEnabled: false).readByte(from: readEnd) == 0x6A)
    }

    @Test("readByte returns nil once the writer has closed, so a picker can exit instead of spinning")
    func readByteReturnsNilAtEOF() {
        let (readEnd, writeEnd) = makePipe()
        defer { close(readEnd) }
        close(writeEnd)

        #expect(CLIOutput(colorsEnabled: false).readByte(from: readEnd) == nil)
    }

    @Test("readByte returns nil for a descriptor that cannot be read")
    func readByteReturnsNilOnReadError() {
        let (readEnd, writeEnd) = makePipe()
        close(readEnd)
        defer { close(writeEnd) }

        // Reading the write end fails with EBADF; the caller must see that as "no key coming".
        #expect(CLIOutput(colorsEnabled: false).readByte(from: writeEnd) == nil)
    }
}
