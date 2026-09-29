#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// termios helpers shared by the raw-mode picker.
///
/// `c_cc` imports as a fixed-size tuple whose length and element order are platform-defined
/// (`NCCS` is 20 on Darwin and 32 on Glibc; `VMIN` is index 16 on Darwin and 6 on Glibc), so the
/// index has to come from the platform's own constant rather than a literal. `tcflag_t` likewise
/// differs — `UInt` on Darwin, `UInt32` on Glibc — so every flag mask is converted through
/// `tcflag_t(...)`.
enum TerminalAttributes {
    /// Reads one control character. Exists for `TerminalAttributesTests`: asserting raw mode
    /// without a TTY is the only way to cover this on both platforms.
    static func controlCharacter(_ attributes: termios, _ index: Int32) -> cc_t {
        withUnsafeBytes(of: attributes.c_cc) { raw in
            raw.bindMemory(to: cc_t.self)[Int(index)]
        }
    }

    static func setControlCharacter(_ attributes: inout termios, _ index: Int32, to value: cc_t) {
        withUnsafeMutableBytes(of: &attributes.c_cc) { raw in
            raw.bindMemory(to: cc_t.self)[Int(index)] = value
        }
    }

    /// Non-canonical, no-echo attributes: one byte satisfies a read and nothing is echoed, so arrow
    /// keys reach the picker as they are typed.
    static func rawMode(from attributes: termios) -> termios {
        var raw = attributes
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        setControlCharacter(&raw, VMIN, to: 1)
        setControlCharacter(&raw, VTIME, to: 0)
        return raw
    }
}
