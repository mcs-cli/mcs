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
        "The child side reads through a hangup and closes only on a bad descriptor",
        arguments: [
            (Int16(POLLIN), PTYBridge.PTYAction.read),
            (Int16(POLLIN | POLLHUP), .read),
            (Int16(POLLHUP), .read),
            (Int16(POLLERR), .close),
            (Int16(POLLNVAL), .close),
            (Int16(POLLIN | POLLERR), .close),
            (Int16(0), .idle),
        ]
    )
    func ptyAction(revents: Int16, expected: PTYBridge.PTYAction) {
        #expect(PTYBridge.ptyAction(revents: revents) == expected)
    }

    @Test("A /dev/null stdin, which macOS reports as POLLNVAL, is dropped rather than polled forever")
    func devNullStdinIsDropped() {
        let fd = open("/dev/null", O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        #expect(poll(&fds, 1, 0) == 1)
        #expect(PTYBridge.stdinAction(revents: fds[0].revents) != .idle)
    }
}
