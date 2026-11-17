import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

struct NativePasteContext: Equatable {
    let uid: String
    let threadID: String
}

/// Reads the pasteboard only after the user chooses Paste. Originals are copied
/// to a protected temporary directory and sent to the composer in bounded chunks.
@MainActor
final class NativeFilePaste {
    private weak var webView: WKWebView?
    private let context: () -> NativePasteContext?
    private let reportError: (String) -> Void
    private var operation: Task<Void, Never>?
    private var operationID: String?
    private static let maxBytes = 100 * 1024 * 1024
    private static let chunkBytes = 256 * 1024

    var isBusy: Bool { operation != nil }

    init(webView: WKWebView, context: @escaping () -> NativePasteContext?, reportError: @escaping (String) -> Void) {
        self.webView = webView
        self.context = context
        self.reportError = reportError
    }

    func paste(fallbackText: String? = nil) {
        guard operation == nil, let expected = context(), !expected.uid.isEmpty else { return }
        let id = UUID().uuidString
        // This is the explicit paste action. No clipboard access occurs during
        // startup, navigation, sign-in, or snapshot updates.
        let pasteboard = UIPasteboard.general
        let items = pasteboard.itemProviders.compactMap(NativePasteItem.init)
        let text = (fallbackText?.isEmpty == false ? fallbackText : nil) ?? pasteboard.string ?? pasteboard.url?.absoluteString
        if items.isEmpty {
            guard let text, !text.isEmpty else { reportError(NativePasteError.unavailable.localizedDescription); return }
            // Text does not acquire the file-operation lock. Consecutive Paste
            // commands are delivered in order instead of dropping the second.
            Task { [weak self] in
                guard let self, self.context() == expected, let webView = self.webView else { return }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        "return window.PrivMsgNative.insertPastedText(payload);",
                        arguments: ["payload": ["text": text, "uid": expected.uid, "threadID": expected.threadID]],
                        in: nil, contentWorld: .page)
                } catch {
                    if self.context() == expected { self.reportError(error.localizedDescription) }
                }
            }
            return
        }
        operationID = id
        operation = Task { [weak self] in
            guard let self else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrivMsgPaste-\(id)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: directory)
                if self.operationID == id { self.operation = nil; self.operationID = nil }
            }
            do {
                try self.check(expected, id: id)
                guard items.count <= 20 else { throw NativePasteError.tooLarge }
                _ = try await self.call("preparePaste", payload: [
                    "id": id, "uid": expected.uid, "threadID": expected.threadID
                ], expected: expected, id: id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete])
                var files: [NativePastedFile] = []
                var total = 0
                for item in items {
                    let file = try await NativePasteLoader.prepare(item, directory: directory, limit: Self.maxBytes)
                    try self.check(expected, id: id)
                    _ = try await self.call("keepPasteAlive", payload: id, expected: expected, id: id)
                    total += file.size
                    guard total <= Self.maxBytes else { throw NativePasteError.tooLarge }
                    files.append(file)
                }
                _ = try await self.call("beginPaste", payload: [
                    "id": id, "uid": expected.uid, "threadID": expected.threadID,
                    "files": files.map { $0.metadata }
                ], expected: expected, id: id)
                for file in files {
                    let handle = try FileHandle(forReadingFrom: file.url)
                    defer { try? handle.close() }
                    var index = 0
                    var sent = 0
                    while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
                        try self.check(expected, id: id)
                        sent += data.count
                        guard sent <= file.size else { throw NativePasteError.changed }
                        _ = try await self.call("appendPaste", payload: [
                            "id": id, "fileID": file.id, "index": index,
                            "base64": data.base64EncodedString()
                        ], expected: expected, id: id)
                        index += 1
                    }
                    guard sent == file.size else { throw NativePasteError.changed }
                }
                _ = try await self.call("commitPaste", payload: id, expected: expected, id: id)
            } catch {
                await self.abort(id)
                if !(error is CancellationError), self.context() == expected, self.operationID == id {
                    self.reportError(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        guard let id = operationID else { return }
        operation?.cancel()
        operation = nil
        operationID = nil
        Task { [weak self] in await self?.abort(id) }
    }

    private func check(_ expected: NativePasteContext, id: String) throws {
        try Task.checkCancellation()
        guard operationID == id, context() == expected else { throw CancellationError() }
    }

    private func call(_ method: String, payload: Any, expected: NativePasteContext, id: String) async throws -> Any? {
        try check(expected, id: id)
        guard let webView else { throw CancellationError() }
        let result = try await webView.callAsyncJavaScript(
            "return await window.PrivMsgNative[method](payload);",
            arguments: ["method": method, "payload": payload], in: nil, contentWorld: .page)
        try check(expected, id: id)
        return result
    }

    private func abort(_ id: String) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript("window.PrivMsgNative?.cancelPaste(id);",
            arguments: ["id": id], in: nil, contentWorld: .page)
    }
}

private struct NativePasteItem: @unchecked Sendable {
    let provider: NSItemProvider
    let typeIdentifier: String
    let suggestedName: String?
    let isFileURL: Bool

    init?(_ provider: NSItemProvider) {
        self.provider = provider
        suggestedName = provider.suggestedName
        isFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        if isFileURL { typeIdentifier = UTType.fileURL.identifier; return }
        guard let identifier = Self.fileType(in: provider) else { return nil }
        typeIdentifier = identifier
    }

    private init(provider: NSItemProvider, typeIdentifier: String, suggestedName: String?) {
        self.provider = provider
        self.typeIdentifier = typeIdentifier
        self.suggestedName = suggestedName
        isFileURL = false
    }

    var binaryAlternative: NativePasteItem? {
        guard let identifier = Self.fileType(in: provider) else { return nil }
        return NativePasteItem(provider: provider, typeIdentifier: identifier, suggestedName: suggestedName)
    }

    private static func fileType(in provider: NSItemProvider) -> String? {
        let attachment = provider.preferredPresentationStyle == .attachment
        return provider.registeredTypeIdentifiers.first(where: { value in
            guard let type = UTType(value), !type.conforms(to: .url) else { return false }
            if type.conforms(to: .text) { return attachment }
            return type.conforms(to: .data) || type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
        })
    }
}

private struct NativePastedFile: Sendable {
    let id: String
    let url: URL
    let name: String
    let mimeType: String
    let size: Int
    let lastModified: Double
    var metadata: [String: Any] {
        ["id": id, "name": name, "type": mimeType, "size": size, "lastModified": lastModified]
    }
}

private enum NativePasteLoader {
    static func prepare(_ item: NativePasteItem, directory: URL, limit: Int) async throws -> NativePastedFile {
        try await withThrowingTaskGroup(of: NativePastedFile.self) { group in
            group.addTask { try await load(item, directory: directory, limit: limit) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw NativePasteError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func load(_ item: NativePasteItem, directory: URL, limit: Int) async throws -> NativePastedFile {
        if item.isFileURL {
            do {
                return try await receive { finish in
                    item.provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                        if let error { finish(.failure(error)); return }
                        let url: URL?
                        if let supplied = value as? URL { url = supplied }
                        else if let data = value as? Data, let string = String(data: data, encoding: .utf8) { url = URL(string: string) }
                        else if let string = value as? String { url = URL(string: string) }
                        else { url = nil }
                        guard let url, url.isFileURL else { finish(.failure(NativePasteError.unavailable)); return }
                        do { finish(.success(try copy(url, item: item, directory: directory, limit: limit))) }
                        catch { finish(.failure(error)) }
                    }
                    return nil
                }
            } catch {
                try Task.checkCancellation()
                if let failure = error as? NativePasteError, failure != .unavailable { throw error }
                guard let alternative = item.binaryAlternative else { throw error }
                return try await load(alternative, directory: directory, limit: limit)
            }
        }
        do {
            return try await receive { finish in
                item.provider.loadFileRepresentation(forTypeIdentifier: item.typeIdentifier) { url, error in
                    if let error { finish(.failure(error)); return }
                    guard let url else { finish(.failure(NativePasteError.unavailable)); return }
                    // Provider URLs are valid only within this completion callback.
                    do { finish(.success(try copy(url, item: item, directory: directory, limit: limit))) }
                    catch { finish(.failure(error)) }
                }
            }
        } catch {
            try Task.checkCancellation()
            if let failure = error as? NativePasteError, failure != .unavailable { throw error }
            return try await receive { finish in
                item.provider.loadDataRepresentation(forTypeIdentifier: item.typeIdentifier) { data, error in
                    if let error { finish(.failure(error)); return }
                    guard let data, !data.isEmpty else { finish(.failure(NativePasteError.unavailable)); return }
                    guard data.count <= limit else { finish(.failure(NativePasteError.tooLarge)); return }
                    let destination = directory.appendingPathComponent(UUID().uuidString)
                    do {
                        try data.write(to: destination, options: .completeFileProtection)
                        finish(.success(try describe(destination, item: item, originalURL: nil)))
                    } catch { finish(.failure(error)) }
                }
            }
        }
    }

    private static func copy(_ source: URL, item: NativePasteItem, directory: URL, limit: Int) throws -> NativePastedFile {
        guard source.isFileURL else { throw NativePasteError.unavailable }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { throw NativePasteError.unavailable }
        guard size.int64Value <= Int64(limit) else { throw NativePasteError.tooLarge }
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        return try describe(destination, item: item, originalURL: source)
    }

    private static func describe(_ url: URL, item: NativePasteItem, originalURL: URL?) throws -> NativePastedFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = item.isFileURL ? originalURL.flatMap { UTType(filenameExtension: $0.pathExtension) } : UTType(item.typeIdentifier)
        var name = item.suggestedName ?? originalURL?.lastPathComponent ?? "Pasted file"
        name = (name as NSString).lastPathComponent.replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        if name.isEmpty || name == "." || name == ".." { name = "Pasted file" }
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension { name += "." + ext }
        return NativePastedFile(id: UUID().uuidString, url: url, name: String(name.prefix(1024)),
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            lastModified: ((attributes[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000)
    }

    private static func receive<T>(_ begin: (@escaping (Result<T, Error>) -> Void) -> Progress?) async throws -> T {
        let transfer = NativeProviderTransfer<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard transfer.install(continuation) else { return }
                transfer.attach(begin { transfer.finish($0) })
            }
        } onCancel: { transfer.cancel() }
    }
}

/// Completes continuations promptly on cancellation even if a provider stops
/// calling back. Late provider completions are ignored and temporary data dies
/// with this paste operation's directory.
private final class NativeProviderTransfer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var progress: Progress?
    private var finished = false

    func install(_ value: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); value.resume(throwing: CancellationError()); return false }
        continuation = value
        lock.unlock()
        return true
    }

    func attach(_ value: Progress?) {
        lock.lock()
        if finished { lock.unlock(); value?.cancel(); return }
        progress = value
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let value = continuation
        continuation = nil
        progress = nil
        lock.unlock()
        value?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let value = progress
        lock.unlock()
        finish(.failure(CancellationError()))
        value?.cancel()
    }
}

private enum NativePasteError: LocalizedError, Equatable {
    case unavailable, tooLarge, timedOut, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The clipboard did not provide a readable file. Use Share > PrivMsg or Upload files. Copied links remain text."
        case .tooLarge: return "Paste up to 20 files totaling 100 MB. Use Upload files for larger items."
        case .timedOut: return "The other app took too long to provide the file. Copy it again, or use Share > PrivMsg."
        case .changed: return "The copied file changed while it was being read. Copy it again."
        }
    }
}
