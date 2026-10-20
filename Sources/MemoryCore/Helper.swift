import Darwin
import Foundation

// The GUI measures all users' processes through the CLI binary running as root
// (`app-memory-report --serve <socket>`). The GUI listens on a Unix socket in its private
// temp directory, starts the helper with administrator privileges and accepts its
// connection. Both sides exchange JSON lines: the GUI sends a `HelperRequest`, the helper
// answers with any number of `.progress` messages and one `.report`. The helper exits when
// the GUI closes the connection.

struct HelperRequest: Codable {
    let limit: Int?
}

enum HelperMessage: Codable {
    case progress([AppUsage])
    case report(rows: [AppUsage], groupCount: Int)
}

public enum HelperError: Error {
    /// The helper didn't connect in time (it failed to start).
    case timeout
    /// The connecting process doesn't run as root.
    case unexpectedPeer
    /// The helper closed the connection or sent something unreadable.
    case disconnected
    case system(String, Int32)
}

/// Runs the helper: connects to the GUI at `socketPath` and measures all users' processes
/// on each request. Returns the exit status once the GUI closes the connection.
public func serveHelper(socketPath: String) -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return 1 }
    let connected = withSocketAddress(socketPath) { connect(fd, $0, $1) } == 0
    let channel = LineChannel(fd: fd)
    guard connected else { return 1 }

    var cache = FootprintCache()
    while let line = channel.readLine() {
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: line) else { return 1 }
        let report = MemoryReport.measure(includeAllUsers: true, includeTotal: false, limit: request.limit,
                                          maxConcurrency: 4, qos: .utility, cache: cache) { rows in
            channel.send(HelperMessage.progress(rows))
        }
        cache = report.cache
        guard channel.send(HelperMessage.report(rows: report.rows, groupCount: report.groupCount)) else {
            return 0
        }
    }
    return 0
}

/// The GUI's end of the connection to a helper running as root. Closing it (releasing the
/// last reference) ends the helper. One request at a time.
public final class HelperConnection: @unchecked Sendable {
    private let channel: LineChannel

    private init(channel: LineChannel) {
        self.channel = channel
    }

    /// Listens on a new socket, calls `launch` with its path to start the helper and waits
    /// up to `timeout` for the helper to connect. `launch` blocks until the helper is started
    /// (or throws, e.g. when the user cancels the password dialog). Only a helper running as
    /// `peerUID` (root, except in tests) is accepted.
    public static func accept(peerUID: uid_t = 0, timeout: Duration = .seconds(10),
                              launching launch: (String) throws -> Void) throws -> HelperConnection {
        // mkdtemp creates the directory with mode 0700, so only the user (and root) can connect.
        var template = Array((NSTemporaryDirectory() + "amr.XXXXXX").utf8CString)
        guard let dirPointer = mkdtemp(&template) else { throw HelperError.system("mkdtemp", errno) }
        let directory = String(cString: dirPointer)
        let path = directory + "/s"
        defer {
            unlink(path)
            rmdir(directory)
        }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HelperError.system("socket", errno) }
        defer { close(listener) }
        guard withSocketAddress(path, { bind(listener, $0, $1) }) == 0 else { throw HelperError.system("bind", errno) }
        guard listen(listener, 1) == 0 else { throw HelperError.system("listen", errno) }

        try launch(path)

        var request = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(timeout.components.seconds * 1000)
        guard poll(&request, 1, milliseconds) == 1 else { throw HelperError.timeout }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { throw HelperError.system("accept", errno) }
        let channel = LineChannel(fd: fd)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == peerUID else { throw HelperError.unexpectedPeer }
        return HelperConnection(channel: channel)
    }

    /// Like `MemoryReport.measure` for all users without the total. Blocks until the helper
    /// is done; `progress` is called on the calling thread.
    public func measure(limit: Int?, progress: ([AppUsage]) -> Void) throws -> (rows: [AppUsage], groupCount: Int) {
        guard channel.send(HelperRequest(limit: limit)) else { throw HelperError.disconnected }
        while let line = channel.readLine() {
            guard let message = try? JSONDecoder().decode(HelperMessage.self, from: line) else {
                throw HelperError.disconnected
            }
            switch message {
            case .progress(let rows): progress(rows)
            case .report(let rows, let groupCount): return (rows, groupCount)
            }
        }
        throw HelperError.disconnected
    }
}

/// Newline-separated JSON over a socket. Sending is thread-safe; the descriptor is closed
/// on deinit.
private final class LineChannel: @unchecked Sendable {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private let sendLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// The next line without its newline, nil at the end of the stream.
    func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer += chunk[..<count]
        }
    }

    /// false if the other side is gone.
    @discardableResult
    func send<T: Encodable>(_ value: T) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(UInt8(ascii: "\n"))
        sendLock.lock()
        defer { sendLock.unlock() }
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

/// Calls `body` with a `sockaddr_un` for `path` (-1 with ENAMETOOLONG if it doesn't fit).
private func withSocketAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        errno = ENAMETOOLONG
        return -1
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
