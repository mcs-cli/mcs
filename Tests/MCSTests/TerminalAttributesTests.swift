#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import mcs
import Testing

struct TerminalAttributesTests {
    @Test("rawMode clears ICANON and ECHO, keeps ISIG, and sets VMIN/VTIME")
    func rawModeFlagsAndControlCharacters() {
        var original = termios()
        original.c_lflag = tcflag_t(ICANON | ECHO | ISIG)

        let raw = TerminalAttributes.rawMode(from: original)

        #expect(raw.c_lflag & tcflag_t(ICANON) == 0)
        #expect(raw.c_lflag & tcflag_t(ECHO) == 0)
        #expect(raw.c_lflag & tcflag_t(ISIG) != 0, "Ctrl-C must still generate SIGINT")
        #expect(TerminalAttributes.controlCharacter(raw, VMIN) == 1)
        #expect(TerminalAttributes.controlCharacter(raw, VTIME) == 0)
    }

    @Test("setControlCharacter writes only the requested index")
    func setControlCharacterIsIndexed() {
        var attributes = termios()
        TerminalAttributes.setControlCharacter(&attributes, VMIN, to: 7)

        #expect(TerminalAttributes.controlCharacter(attributes, VMIN) == 7)
        #expect(TerminalAttributes.controlCharacter(attributes, VTIME) == 0)
    }
}
