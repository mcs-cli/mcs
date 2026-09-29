#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The per-descriptor decisions of `ShellRunner.runInteractive`'s poll loop, kept free of I/O so
/// every `revents` combination can be tabled in a test.
///
/// Two facts drive the shapes below. `poll(2)` reports `POLLHUP`, `POLLERR` and `POLLNVAL`
/// whether or not they were requested, so a descriptor that keeps reporting one of them without
/// `POLLIN` makes `poll` return immediately, forever, unless the loop stops watching it — macOS
/// returns `POLLNVAL` for a `/dev/null` stdin, which is what a hook or `mcs sync --all </dev/null`
/// hands a `shellInteractive` component. And a hung-up pipe can still carry buffered bytes, so
/// readable data is always drained before the descriptor is dropped.
enum PTYBridge {
    /// What to do with the user's terminal this iteration.
    enum StdinAction: Equatable {
        /// Bytes are waiting; forward them to the child.
        case forward
        /// Nothing to read and nothing coming; stop polling the descriptor.
        case drop
        case idle
    }

    /// What to do with the child's PTY this iteration.
    enum PTYAction: Equatable {
        /// Output is waiting, or the child hung up with output possibly still buffered.
        case read
        /// The descriptor itself is bad; the command is gone and the bridge ends.
        case close
        case idle
    }

    static func stdinAction(revents: Int16) -> StdinAction {
        if revents & Int16(POLLIN) != 0 { return .forward }
        if revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return .drop }
        return .idle
    }

    static func ptyAction(revents: Int16) -> PTYAction {
        if revents & Int16(POLLERR | POLLNVAL) != 0 { return .close }
        if revents & Int16(POLLIN | POLLHUP) != 0 { return .read }
        return .idle
    }
}
