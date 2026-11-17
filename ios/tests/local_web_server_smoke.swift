import Darwin
import Foundation

/// Runs the app's actual Network.framework listener on macOS, without UIKit.
/// A compilation-only check cannot detect an invalid NWListener configuration.
@main
struct LocalWebServerSmoke {
    @MainActor
    static func main() async {
        do {
            try await run()
            print("PASS: loopback startup, GET, Host/path restrictions, and same-port restart")
        } catch {
            FileHandle.standardError.write(Data("Local web server smoke failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("privmsg-server-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data("<!doctype html><title>PrivMsg server smoke</title>".utf8)
        try expected.write(to: directory.appendingPathComponent("index.html"))
        for name in ["clipboard.js", "enhancements.js", "native-bridge.js"] {
            try Data("// smoke fixture\n".utf8).write(to: directory.appendingPathComponent(name))
        }
        // Even another real file in the same directory must remain inaccessible.
        try Data("private fixture".utf8).write(to: directory.appendingPathComponent("secret.txt"))

        let server = LocalWebServer(resourceDirectory: directory)
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await server.start()
        try await verifyIndex(server.baseURL, expected: expected, session: session)
        // Calling start twice while ready must not create a second listener.
        try await server.start()
        let host = "127.0.0.1:\(LocalWebServer.port)"
        try await expectStatus(403, path: "/", host: "untrusted.example")
        try await expectStatus(404, path: "/secret.txt", host: host)
        try await expectStatus(404, path: "/../secret.txt", host: host)
        try await expectStatus(404, path: "/%2e%2e/secret.txt", host: host)

        server.stop()
        // Network.framework cancellation runs asynchronously on its queue.
        try await Task.sleep(nanoseconds: 250_000_000)
        try await server.start()
        try await verifyIndex(server.baseURL, expected: expected, session: session)
    }

    private static func verifyIndex(_ url: URL, expected: Data, session: URLSession) async throws {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data == expected else {
            throw SmokeFailure("GET did not return the exact bundled index with HTTP 200")
        }
    }

    @MainActor
    private static func expectStatus(_ status: Int, path: String, host: String) async throws {
        let port = LocalWebServer.port
        let response = try await Task.detached {
            try rawRequest(port: port, path: path, host: host)
        }.value
        guard response.hasPrefix("HTTP/1.1 \(status) ") else {
            throw SmokeFailure("Unexpected response for \(path): \(response.prefix(100))")
        }
    }

    // A raw socket preserves deliberately invalid Host/path values. URLSession
    // may normalize them, which would not test the server's own restrictions.
    private static func rawRequest(port: UInt16, path: String, host: String) throws -> String {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketFailure("socket") }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0 else {
            throw socketFailure("setsockopt timeout")
        }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw socketFailure("setsockopt SO_NOSIGPIPE")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw SmokeFailure("Invalid loopback address")
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw socketFailure("connect") }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
        try request.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw SmokeFailure("Empty request") }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw socketFailure("send") }
                sent += count
            }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw socketFailure("recv") }
            if count == 0 { break }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count < 64 * 1024 else { throw SmokeFailure("Unbounded HTTP response") }
        }
        guard let text = String(data: response, encoding: .utf8) else {
            throw SmokeFailure("Non-UTF-8 HTTP response")
        }
        return text
    }

    private static func socketFailure(_ operation: String) -> SmokeFailure {
        SmokeFailure("\(operation): \(String(cString: strerror(errno)))")
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
