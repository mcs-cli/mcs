import Foundation
@testable import mcs
import Testing

struct PTYBridgeTests {
    @Test(
        "The terminal side forwards while readable and drops only once nothing more can arrive",
        arguments: [
            (Int16(POLLIN), PTYBridge.StdinAction.forward),
            (Int16(POLLIN | POLLHUP), .forward),
            (Int16(POLLHUP), .drop),
            (Int16(POLLERR), .drop),
            (Int16(POLLNVAL), .drop),
            (Int16(0), .idle),
        ]
    )
    func stdinAction(revents: Int16, expected: PTYBridge.StdinAction) {
        #expect(PTYBridge.stdinAction(revents: revents) == expected)
    }

    @Test(
        "The child side drains what is readable and closes only once nothing is left",
        arguments: [
            (Int16(POLLIN), PTYBridge.PTYAction.read),
            (Int16(POLLIN | POLLHUP), .read),
            (Int16(POLLHUP), .read),
            (Int16(POLLERR), .close),
            (Int16(POLLNVAL), .close),
            (Int16(POLLIN | POLLERR), .read),
            (Int16(0), .idle),
        ]
    )
    func ptyAction(revents: Int16, expected: PTYBridge.PTYAction) {
        #expect(PTYBridge.ptyAction(revents: revents) == expected)
    }

    @Test("A /dev/null stdin is never left idle, so the bridge cannot poll it forever")
    func devNullStdinIsNotPolledForever() {
        let fd = open("/dev/null", O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        #expect(poll(&fds, 1, 0) == 1)
        #if canImport(Darwin)
        // macOS reports POLLNVAL for /dev/null, with nothing to read.
        #expect(PTYBridge.stdinAction(revents: fds[0].revents) == .drop)
        #else
        // Linux reports it readable; the bridge's read then returns 0 and drops the descriptor.
        #expect(PTYBridge.stdinAction(revents: fds[0].revents) == .forward)
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)
        #endif
    }
}
