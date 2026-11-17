import Foundation
import Network

/// Serves bundled application code only. User data, credentials and exported
/// attachments never pass through this listener.
@MainActor
final class LocalWebServer {
    static let port: UInt16 = 47835

    var baseURL: URL { URL(string: "http://127.0.0.1:\(Self.port)/")! }

    private let resourceDirectory: URL
    private let queue = DispatchQueue(label: "com.jordanrapp.PrivMsg.static-web")
    private var listener: NWListener?
    private var generation: UUID?
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var startupTimeout: Task<Void, Never>?
    private var connections: [UUID: StaticHTTPConnection] = [:]

    init(resourceDirectory: URL) {
        self.resourceDirectory = resourceDirectory
    }

    func start() async throws {
        try Task.checkCancellation()
        if ready { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[waiterID] = continuation
                if listener == nil {
                    do { try makeListener() }
                    catch { terminate(error: error) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    func stop() {
        terminate(error: CancellationError())
    }

    private func makeListener() throws {
        let assets = try loadAssets()
        let port = NWEndpoint.Port(rawValue: Self.port)!
        let parameters = NWParameters.tcp
        // Explicit binding is essential: an unspecified listener address would
        // expose the server to Wi-Fi and other network interfaces.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let newListener = try NWListener(using: parameters, on: port)
        let currentGeneration = UUID()
        generation = currentGeneration
        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else {
                    connection.cancel()
                    return
                }
                self.accept(connection, assets: assets)
            }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.startupTimeout?.cancel()
                    self.startupTimeout = nil
                    self.completeWaiters(with: .success(()))
                case .failed(let error):
                    self.terminate(error: ServerError.listener(error.localizedDescription))
                case .cancelled:
                    self.terminate(error: CancellationError())
                default:
                    break
                }
            }
        }
        startupTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            guard let self, self.generation == currentGeneration, !self.ready else { return }
            self.terminate(error: ServerError.startupTimedOut)
        }
        newListener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection, assets: [String: StaticAsset]) {
        // Modules load in parallel; this cap is well above the app's needs.
        guard connections.count < 32 else {
            connection.cancel()
            return
        }
        let id = UUID()
        let request = StaticHTTPConnection(
            connection: connection,
            queue: queue,
            assets: assets,
            expectedHost: "127.0.0.1:\(Self.port)"
        ) { [weak self] in
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        }
        connections[id] = request
        request.start()
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if waiters.isEmpty && !ready { terminate(error: CancellationError()) }
    }

    private func completeWaiters(with result: Result<Void, Error>) {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }

    private func terminate(error: Error) {
        ready = false
        generation = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        let oldListener = listener
        listener = nil
        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil
        oldListener?.cancel()
        let pendingConnections = Array(connections.values)
        connections.removeAll()
        for connection in pendingConnections { connection.cancel() }
        completeWaiters(with: .failure(error))
    }

    private func loadAssets() throws -> [String: StaticAsset] {
        // Exact filenames form the allowlist. No URL ever becomes a filesystem
        // path, and requests cannot reach caches or Documents directories.
        let files: [(String, String, Bool)] = [
            ("index.html", "text/html; charset=utf-8", true),
            ("clipboard.js", "text/javascript; charset=utf-8", true),
            ("enhancements.js", "text/javascript; charset=utf-8", true),
            ("native-bridge.js", "text/javascript; charset=utf-8", true),
            ("IMG_0630.webp", "image/webp", false),
            ("app-icon.png", "image/png", false),
            ("favicon.ico", "image/x-icon", false)
        ]
        var result: [String: StaticAsset] = [:]
        for (name, contentType, required) in files {
            let url = resourceDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if required { throw ServerError.missingAsset(name) }
                continue
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 4 * 1024 * 1024 else {
                throw ServerError.assetTooLarge(name)
            }
            result["/\(name)"] = StaticAsset(data: data, contentType: contentType)
        }
        result["/"] = result["/index.html"]
        return result
    }

    enum ServerError: LocalizedError {
        case missingAsset(String)
        case assetTooLarge(String)
        case listener(String)
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .missingAsset(let name): return "The app is missing \(name). Rebuild PrivMsg in Xcode."
            case .assetTooLarge(let name): return "The bundled file \(name) is unexpectedly large. Rebuild PrivMsg."
            case .listener(let reason): return "PrivMsg could not start its local page: \(reason)"
            case .startupTimedOut: return "PrivMsg's local page took too long to start. Close and reopen the app."
            }
        }
    }
}

private struct StaticAsset: Sendable {
    let data: Data
    let contentType: String
}

/// All mutable state below belongs exclusively to `queue` after construction.
private final class StaticHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let assets: [String: StaticAsset]
    private let expectedHost: String
    private let onClose: @Sendable () -> Void
    private var bytes = Data()
    private var timeout: DispatchWorkItem?
    private var finished = false
    private var responding = false
    private let headerLimit = 16 * 1024

    init(connection: NWConnection, queue: DispatchQueue, assets: [String: StaticAsset],
         expectedHost: String, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.assets = assets
        self.expectedHost = expectedHost
        self.onClose = onClose
    }

    func start() {
        queue.async { [self] in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.receiveHeader()
                case .failed, .cancelled: self.finish()
                default: break
                }
            }
            let deadline = DispatchWorkItem { [weak self] in self?.finish() }
            timeout = deadline
            queue.asyncAfter(deadline: .now() + 10, execute: deadline)
            connection.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.finish() }
    }

    private func receiveHeader() {
        guard !finished, !responding else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.finished, !self.responding else { return }
            if let data { self.bytes.append(data) }
            guard self.bytes.count <= self.headerLimit else {
                self.respond(status: "431 Request Header Fields Too Large", body: Data())
                return
            }
            if let end = self.bytes.range(of: Data("\r\n\r\n".utf8)) {
                self.handleHeader(self.bytes[..<end.lowerBound])
            } else if error != nil || complete {
                self.finish()
            } else {
                self.receiveHeader()
            }
        }
    }

    private func handleHeader(_ data: Data) {
        guard let header = String(data: data, encoding: .utf8) else {
            respond(status: "400 Bad Request", body: Data())
            return
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else {
            respond(status: "400 Bad Request", body: Data())
            return
        }
        let method = String(request[0])
        guard method == "GET" || method == "HEAD" else {
            respond(status: "405 Method Not Allowed", body: Data(), extraHeaders: ["Allow": "GET, HEAD"])
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                respond(status: "400 Bad Request", body: Data())
                return
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else {
                respond(status: "400 Bad Request", body: Data())
                return
            }
            headers[name] = value
        }
        // Require the intended origin, not a DNS name pointed at loopback.
        guard headers["host"] == expectedHost else {
            respond(status: "403 Forbidden", body: Data())
            return
        }
        guard headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else {
            respond(status: "400 Bad Request", body: Data())
            return
        }
        let target = String(request[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard let asset = assets[path] else {
            respond(status: "404 Not Found", body: Data(), headOnly: method == "HEAD")
            return
        }
        respond(status: "200 OK", body: asset.data, contentType: asset.contentType, headOnly: method == "HEAD")
    }

    private func respond(status: String, body: Data, contentType: String = "text/plain; charset=utf-8",
                         headOnly: Bool = false, extraHeaders: [String: String] = [:]) {
        guard !finished, !responding else { return }
        responding = true
        let csp = [
            "default-src 'none'",
            "script-src 'self' 'unsafe-inline' https://www.gstatic.com blob:",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "font-src 'self'",
            "media-src 'self' data: blob:",
            "worker-src 'self' blob:",
            "connect-src 'self' https://*.googleapis.com https://*.cloudfunctions.net https://*.firebaseapp.com wss://*.firebaseio.com",
            "frame-src https://privmsg-stream.firebaseapp.com",
            "frame-ancestors 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "object-src 'none'"
        ].joined(separator: "; ")
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: \(csp)"
        ]
        for (name, value) in extraHeaders { headers.append("\(name): \(value)") }
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        bytes.removeAll(keepingCapacity: false)
        onClose()
    }
}
