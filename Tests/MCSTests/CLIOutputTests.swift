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

        #expect(CLIOutput(colorsEnabled: false, input: readEnd).readByte() == 0x6A)
    }

    @Test("readByte returns nil once the writer has closed, so a picker can exit instead of spinning")
    func readByteReturnsNilAtEOF() {
        let (readEnd, writeEnd) = makePipe()
        defer { close(readEnd) }
        close(writeEnd)

        #expect(CLIOutput(colorsEnabled: false, input: readEnd).readByte() == nil)
    }

    @Test("readByte returns nil for a descriptor that cannot be read")
    func readByteReturnsNilOnReadError() {
        let (readEnd, writeEnd) = makePipe()
        close(readEnd)
        defer { close(writeEnd) }

        // Reading the write end fails with EBADF; the caller must see that as "no key coming".
        #expect(CLIOutput(colorsEnabled: false, input: writeEnd).readByte() == nil)
    }

    private func outputWithClosedInput() -> (CLIOutput, Int32) {
        // A pipe whose writer has closed: the hangup a raw-mode prompt sees.
        let (readEnd, writeEnd) = makePipe()
        close(writeEnd)
        return (CLIOutput(colorsEnabled: false, input: readEnd), readEnd)
    }

    @Test("A yes/no prompt that loses its input throws instead of answering, even with a Yes default")
    func yesNoThrowsWhenInputCloses() {
        let (output, fd) = outputWithClosedInput()
        defer { close(fd) }
        #expect(throws: InputClosedError.self) { try output.interactiveYesNo("Proceed?", default: true) }
    }

    @Test("A single-select that loses its input throws instead of returning the cursor")
    func singleSelectThrowsWhenInputCloses() {
        let (output, fd) = outputWithClosedInput()
        defer { close(fd) }
        #expect(throws: InputClosedError.self) {
            try output.interactiveSingleSelect(title: "Pick", items: [("a", ""), ("b", "")], initialIndex: 1)
        }
    }

    @Test("A multi-select that loses its input throws instead of applying unconfirmed toggles")
    func multiSelectThrowsWhenInputCloses() {
        let (output, fd) = outputWithClosedInput()
        defer { close(fd) }
        var groups = [SelectableGroup(title: "Packs", items: [SelectableItem(number: 1, name: "a", description: "", isSelected: true)])]
        #expect(throws: InputClosedError.self) { try output.interactiveMultiSelect(groups: &groups) }
    }
}
