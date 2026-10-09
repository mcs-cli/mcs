#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import mcs
import Testing

struct TerminalAttributesTests {
    @Test("rawMode clears ICANON, ECHO and ISIG, and sets VMIN/VTIME at the platform's indices")
    func rawModeFlagsAndControlCharacters() {
        var original = termios()
        original.c_lflag = tcflag_t(ICANON | ECHO | ISIG)
        // Seeded opposite to what raw mode wants, so a write to the wrong index cannot pass.
        setControlCharacter(&original, VMIN, to: 0)
        setControlCharacter(&original, VTIME, to: 5)

        let raw = TerminalAttributes.rawMode(from: original)

        #expect(raw.c_lflag & tcflag_t(ICANON) == 0)
        #expect(raw.c_lflag & tcflag_t(ECHO) == 0)
        // Ctrl-C has to arrive as a byte: a SIGINT would kill the process before the picker could
        // restore these attributes, leaving the terminal with no echo and no cursor.
        #expect(raw.c_lflag & tcflag_t(ISIG) == 0, "Ctrl-C must reach the picker instead of signalling")
        #expect(controlCharacter(raw, VMIN) == 1)
        #expect(controlCharacter(raw, VTIME) == 0)
    }

    private func controlCharacter(_ attributes: termios, _ index: Int32) -> cc_t {
        withUnsafeBytes(of: attributes.c_cc) { $0.bindMemory(to: cc_t.self)[Int(index)] }
    }

    private func setControlCharacter(_ attributes: inout termios, _ index: Int32, to value: cc_t) {
        withUnsafeMutableBytes(of: &attributes.c_cc) { $0.bindMemory(to: cc_t.self)[Int(index)] = value }
    }
}
