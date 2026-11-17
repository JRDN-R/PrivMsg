import Foundation
import UniformTypeIdentifiers

/// Wraps provider callbacks so cancellation resumes an awaiting task exactly once
/// and cancels the provider's outstanding progress as well.
private final class ProviderLoad<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<Value, Error>, operation: (@escaping (Result<Value, Error>) -> Void) -> Progress?) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        lock.unlock()
        let progress = operation { [weak self] result in self?.finish(result) }
        lock.lock()
        self.progress = progress
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { progress?.cancel() }
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }

    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = continuation
        let progress = progress
        continuation = nil
        lock.unlock()
        progress?.cancel()
        current?.resume(throwing: CancellationError())
    }
}

/// Copies provider-owned file representations while their callback URL is valid.
/// Only a 512 KiB buffer is held while copying; remote links are never downloaded.
final class ShareItemReader: @unchecked Sendable {
    static let maximumFiles = 20
    static let maximumBytes: Int64 = 100 * 1024 * 1024
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivMsgShare-" + UUID().uuidString, isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func read(_ items: [NSExtensionItem]) async throws -> ShareInput {
        var files: [SharedFile] = []
        var text: [String] = []
        var bytes: Int64 = 0
        func addText(_ value: String) throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !text.contains(trimmed) else { return }
            guard trimmed.utf8.count <= 100_000,
                  text.reduce(0, { $0 + $1.utf8.count }) + trimmed.utf8.count <= 100_000 else {
                throw ShareFailure.message("This shared text is too long. Share a text file instead.")
            }
            text.append(trimmed)
        }
        for item in items {
            try Task.checkCancellation()
            if let body = item.attributedContentText?.string { try addText(body) }
            for provider in item.attachments ?? [] {
                try Task.checkCancellation()
                if let identifier = preferredFileType(provider) {
                    guard files.count < Self.maximumFiles else { throw ShareFailure.message("Share up to 20 files at a time.") }
                    let file = try await readFile(provider, identifier: identifier, remaining: Self.maximumBytes - bytes)
                    files.append(file)
                    bytes += file.size
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    guard files.count < Self.maximumFiles else { throw ShareFailure.message("Share up to 20 files at a time.") }
                    let file = try await readFileURL(provider, remaining: Self.maximumBytes - bytes)
                    files.append(file)
                    bytes += file.size
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let value = try await readText(provider, identifier: UTType.url.identifier)
                    try addText(value)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    try addText(try await readText(provider, identifier: UTType.plainText.identifier))
                } else {
                    throw ShareFailure.message("The source app did not provide a readable file or text. Save the file to Files, then share it to PrivMsg.")
                }
            }
        }
        guard !files.isEmpty || !text.isEmpty else { throw ShareFailure.message("No files or text were shared. Choose a file, then share it to PrivMsg.") }
        return ShareInput(files: files, text: text.joined(separator: "\n\n"))
    }

    private func preferredFileType(_ provider: NSItemProvider) -> String? {
        if let binary = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier), !type.conforms(to: .url), !type.conforms(to: .text) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .content)
        }) { return binary }
        // A named text document still needs its original file identity. An
        // ordinary shared string has no suggested filename and stays text.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return nil }
        guard provider.suggestedName?.isEmpty == false else { return nil }
        return provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .text) == true }
    }

    private func readFile(_ provider: NSItemProvider, identifier: String, remaining: Int64) async throws -> SharedFile {
        let load = ProviderLoad<SharedFile>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.start(continuation) { completion in
                    provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                        do {
                            try load.checkCancellation()
                            guard let url else {
                                throw error ?? ShareFailure.message("The source app could not provide \(provider.suggestedName ?? "this file"). Save it to Files, then share it again.")
                            }
                            completion(.success(try self.copyFile(url, name: provider.suggestedName, type: UTType(identifier), remaining: remaining, checkCancellation: load.checkCancellation)))
                        } catch { completion(.failure(error)) }
                    }
                }
            }
        } onCancel: { load.cancel() }
    }

    private func readFileURL(_ provider: NSItemProvider, remaining: Int64) async throws -> SharedFile {
        let load = ProviderLoad<SharedFile>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.start(continuation) { completion in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        do {
                            try load.checkCancellation()
                            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                            guard let url, url.isFileURL else {
                                throw error ?? ShareFailure.message("The source app did not provide a readable file URL. Save to Files, then share again.")
                            }
                            completion(.success(try self.copyFile(url, name: provider.suggestedName, type: nil, remaining: remaining, checkCancellation: load.checkCancellation)))
                        } catch { completion(.failure(error)) }
                    }
                    return nil
                }
            }
        } onCancel: { load.cancel() }
    }

    private func readText(_ provider: NSItemProvider, identifier: String) async throws -> String {
        let load = ProviderLoad<String>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.start(continuation) { completion in
                    provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                        do {
                            try load.checkCancellation()
                            if let url = item as? URL {
                                guard !url.isFileURL else { throw ShareFailure.message("The source app shared a file URL without access to its file. Save it to Files, then share again.") }
                                completion(.success(url.absoluteString))
                            } else if let value = item as? String {
                                completion(.success(value))
                            } else if let data = item as? Data, data.count <= 100_000, let value = String(data: data, encoding: .utf8) {
                                completion(.success(value))
                            } else { throw error ?? ShareFailure.message("The source app's shared text could not be read.") }
                        } catch { completion(.failure(error)) }
                    }
                    return nil
                }
            }
        } onCancel: { load.cancel() }
    }

    private func copyFile(_ source: URL, name: String?, type: UTType?, remaining: Int64,
                          checkCancellation: () throws -> Void) throws -> SharedFile {
        try checkCancellation()
        guard source.isFileURL else { throw ShareFailure.message("A file was expected. Remote links can only be shared as text.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw ShareFailure.message("Folders cannot be shared directly. Compress the folder in Files, then share the ZIP.") }
        guard Int64(values.fileSize ?? 0) <= remaining else { throw ShareFailure.message("Share up to 100 MB of files at a time.") }
        let detected = values.contentType
        let contentType = (detected == .data || detected == .content || detected == .item ? nil : detected)
            ?? type ?? UTType(filenameExtension: source.pathExtension) ?? .data
        var filename = (name?.isEmpty == false ? name! : source.lastPathComponent)
            .components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))).joined(separator: "_")
        if (filename as NSString).pathExtension.isEmpty, let ext = contentType.preferredFilenameExtension { filename += "." + ext }
        if filename.isEmpty { filename = "Shared file" }
        filename = String(filename.prefix(255))
        let target = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ShareFailure.message("Could not prepare a local copy of the shared file.") }
        var successful = false
        defer { if !successful { try? FileManager.default.removeItem(at: target) } }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var size: Int64 = 0
        while true {
            try checkCancellation()
            let data = try input.read(upToCount: 512 * 1024) ?? Data()
            if data.isEmpty { break }
            size += Int64(data.count)
            guard size <= remaining else { throw ShareFailure.message("Share up to 100 MB of files at a time.") }
            try output.write(contentsOf: data)
        }
        try checkCancellation()
        guard size > 0 else { throw ShareFailure.message("\(filename) is empty. Add content to the file before sharing it.") }
        successful = true
        return SharedFile(url: target, name: filename, mimeType: contentType.preferredMIMEType ?? "application/octet-stream", size: size)
    }
}
