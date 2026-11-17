import Foundation
import UniformTypeIdentifiers

struct NativeSession: Codable, Sendable {
    let uid: String
    let token: String
    let projectID: String
}

struct NativeAttachment: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let key: String
    let name: String
    let mimeType: String
    let size: Int64
    let chunks: Int
    let owner: String
    let messageId: String
    let encoding: String?

    var contentType: UTType {
        if !mimeType.isEmpty, let type = UTType(mimeType: mimeType), type != .data {
            return type
        }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Only the leaf filename reaches disk, inside a private per-attachment folder.
    var safeFilename: String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var value = name.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        if value.isEmpty { value = "attachment" }
        let ext = (value as NSString).pathExtension
        var stem = (value as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + String(ext.prefix(20))
        while (stem + suffix).utf8.count > 220, !stem.isEmpty { stem.removeLast() }
        return (stem.isEmpty ? "attachment" : stem) + suffix
    }
}

enum AttachmentError: LocalizedError {
    case invalidMetadata
    case unauthorized
    case missingChunk
    case invalidChunk
    case server(Int)
    case couldNotCreateFile
    case noSelection

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "This attachment's file information is incomplete or unsupported."
        case .unauthorized: return "Your session changed or expired. Return to the conversation, sign in, and try again."
        case .missingChunk: return "Some of this file's data is missing. Try uploading the original again."
        case .invalidChunk: return "The downloaded file did not match its saved information. Please try again."
        case .server(let status): return "The file server could not complete the download (HTTP \(status))."
        case .couldNotCreateFile: return "The file could not be saved on this iPhone. Check available storage and try again."
        case .noSelection: return "Select at least one file to share."
        }
    }
}
