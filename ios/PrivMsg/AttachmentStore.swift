import Foundation
import UIKit
import CryptoKit

/// Reassembles the web app's original Firestore chunks without loading a whole
/// attachment into memory. ID tokens stay in memory and are never written to disk.
@MainActor
final class AttachmentStore {
    private let sessionProvider: () async throws -> NativeSession
    private let root: URL
    private var downloads: [String: Task<URL, Error>] = [:]
    private var cached: [String: URL] = [:]
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    private var generation = 0
    private let limiter = FileTransferLimiter()
    var onProgress: ((String, Double) -> Void)?
    var sessionGeneration: Int { generation }

    init(sessionProvider: @escaping () async throws -> NativeSession) {
        self.sessionProvider = sessionProvider
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivMsgFileTransfers", isDirectory: true)
        // Transfers from a previous process are no longer needed by its providers.
        try? FileManager.default.removeItem(at: root)
    }

    func fileURL(for attachment: NativeAttachment) async throws -> URL {
        let requestGeneration = generation
        let session = try await sessionProvider()
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        try Self.validate(attachment, session: session)
        let cacheKey = Self.digest(session.uid + "|" + attachment.id + "|" + attachment.key + "|" + String(attachment.size))
        if let url = cached[cacheKey], FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let task = downloads[cacheKey] {
            let result = try await task.value
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            return result
        }

        let directory = root.appendingPathComponent(Self.digest(session.uid), isDirectory: true)
            .appendingPathComponent("session-\(requestGeneration)", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)
        let target = directory.appendingPathComponent(attachment.safeFilename, isDirectory: false)
        let partial = directory.appendingPathComponent(".transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var excludedDirectory = directory
        try excludedDirectory.setResourceValues(directoryValues)

        let background = UIApplication.shared.beginBackgroundTask(withName: "PrivMsg file transfer") { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == requestGeneration else { return }
                self.downloads[cacheKey]?.cancel()
            }
        }
        backgroundTasks[cacheKey] = background
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            await self.limiter.acquire()
            do {
                let url = try await Self.download(attachment, session: session, partial: partial, target: target) { progress in
                    await MainActor.run {
                        if self.generation == requestGeneration { self.onProgress?(attachment.id, progress) }
                    }
                }
                await self.limiter.release()
                return url
            } catch {
                await self.limiter.release()
                throw error
            }
        }
        downloads[cacheKey] = task
        defer {
            if requestGeneration == generation {
                downloads.removeValue(forKey: cacheKey)
                if let identifier = backgroundTasks.removeValue(forKey: cacheKey), identifier != .invalid {
                    UIApplication.shared.endBackgroundTask(identifier)
                }
            }
        }
        do {
            let result = try await task.value
            guard requestGeneration == generation else {
                try? FileManager.default.removeItem(at: result)
                throw CancellationError()
            }
            cached[cacheKey] = result
            try Task.checkCancellation()
            return result
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Call whenever the web session signs out or switches user. A pending
    /// provider receives cancellation rather than another user's cached bytes.
    func clear() {
        generation += 1
        for task in downloads.values { task.cancel() }
        downloads.removeAll()
        cached.removeAll()
        for identifier in backgroundTasks.values where identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        backgroundTasks.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ attachment: NativeAttachment, session: NativeSession) throws {
        guard session.projectID == "privmsg-stream", !session.uid.isEmpty, !session.token.isEmpty,
              attachment.owner == session.uid else { throw AttachmentError.unauthorized }
        let chunkBytes: Int64 = 512 * 1024
        let keyCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !attachment.id.isEmpty, !attachment.messageId.isEmpty,
              !attachment.key.isEmpty, attachment.key.count <= 128,
              attachment.key.unicodeScalars.allSatisfy({ keyCharacters.contains($0) }),
              attachment.size > 0, attachment.size <= 4 * 1024 * 1024 * 1024,
              attachment.chunks > 0, attachment.chunks <= 16384 else {
            throw AttachmentError.invalidMetadata
        }
        if attachment.encoding == "base64-chunk-v1",
           Int64(attachment.chunks) != (attachment.size + chunkBytes - 1) / chunkBytes {
            throw AttachmentError.invalidMetadata
        }
    }

    private struct Document: Decodable {
        struct Value: Decodable {
            let stringValue: String?
            let integerValue: String?
        }
        let fields: [String: Value]
    }

    // This nonisolated operation runs away from the UI actor. Each response is
    // at most one Firestore document and each decoded buffer is one 512 KiB chunk.
    nonisolated private static func download(
        _ attachment: NativeAttachment, session: NativeSession, partial: URL, target: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw AttachmentError.couldNotCreateFile
        }
        let handle = try FileHandle(forWritingTo: partial)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: partial) }
        }
        var total: Int64 = 0
        let binaryChunks = attachment.encoding == "base64-chunk-v1"
        var legacyHeader = ""
        var legacyHeaderRead = false
        var base64Remainder = ""
        for index in 0..<attachment.chunks {
            try Task.checkCancellation()
            let documentID = "chunk_\(attachment.key)_\(index)"
            let url = URL(string: "https://firestore.googleapis.com/v1/projects/privmsg-stream/databases/(default)/documents/drops/\(documentID)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await network.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AttachmentError.server(0) }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw AttachmentError.unauthorized
            case 404: throw AttachmentError.missingChunk
            default: throw AttachmentError.server(http.statusCode)
            }
            // A Firestore document is limited to 1 MiB. Permit JSON overhead,
            // but reject an unexpected response before decoding its base64 field.
            guard data.count <= 2 * 1024 * 1024 else { throw AttachmentError.invalidChunk }
            let document = try JSONDecoder().decode(Document.self, from: data)
            let fields = document.fields
            guard let encoded = fields["data"]?.stringValue else { throw AttachmentError.invalidChunk }
            let bytes: Data
            if binaryChunks {
                guard fields["kind"]?.stringValue == "chunk",
                      fields["encoding"]?.stringValue == "base64-chunk-v1",
                      fields["key"]?.stringValue == attachment.key,
                      fields["owner"]?.stringValue == session.uid,
                      Int(fields["index"]?.integerValue ?? "") == index,
                      let decoded = Data(base64Encoded: encoded) else { throw AttachmentError.invalidChunk }
                let expectedBytes = min(Int64(512 * 1024), attachment.size - total)
                guard Int64(decoded.count) == expectedBytes else { throw AttachmentError.invalidChunk }
                bytes = decoded
            } else {
                // Early PrivMsg versions split ONE data URL across documents,
                // including potentially inside a base64 quartet. Optional old
                // metadata is checked when present; Firestore rules still apply.
                if let owner = fields["owner"]?.stringValue, owner != session.uid { throw AttachmentError.unauthorized }
                if let key = fields["key"]?.stringValue, key != attachment.key { throw AttachmentError.invalidChunk }
                if let number = fields["index"]?.integerValue, Int(number) != index { throw AttachmentError.invalidChunk }
                var fragment = encoded
                if !legacyHeaderRead {
                    if let comma = fragment.firstIndex(of: ",") {
                        legacyHeader += String(fragment[..<comma])
                        guard legacyHeader.utf8.count <= 1024, legacyHeader.hasPrefix("data:"),
                              legacyHeader.lowercased().hasSuffix(";base64") else { throw AttachmentError.invalidChunk }
                        fragment = String(fragment[fragment.index(after: comma)...])
                        legacyHeaderRead = true
                        legacyHeader = ""
                    } else {
                        legacyHeader += fragment
                        guard legacyHeader.utf8.count <= 1024 else { throw AttachmentError.invalidChunk }
                        continue
                    }
                }
                let encodedBytes = Array((base64Remainder + fragment).utf8)
                guard encodedBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61 }) else { throw AttachmentError.invalidChunk }
                let count = encodedBytes.count - encodedBytes.count % 4
                let completePart = Data(encodedBytes.prefix(count))
                base64Remainder = String(decoding: encodedBytes.dropFirst(count), as: UTF8.self)
                guard index == attachment.chunks - 1 || !completePart.contains(61),
                      let decoded = Data(base64Encoded: completePart) else { throw AttachmentError.invalidChunk }
                bytes = decoded
            }
            guard total + Int64(bytes.count) <= attachment.size else { throw AttachmentError.invalidChunk }
            try handle.write(contentsOf: bytes)
            total += Int64(bytes.count)
            await progress(Double(total) / Double(attachment.size))
        }
        guard total == attachment.size, binaryChunks || (legacyHeaderRead && base64Remainder.isEmpty) else { throw AttachmentError.invalidChunk }
        try Task.checkCancellation()
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: partial, to: target)
        completed = true
        return target
    }
}

/// Limits simultaneous file downloads, not just chunks within a single file.
/// Cancellation is checked immediately when a queued request receives its slot.
private actor FileTransferLimiter {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }
}
