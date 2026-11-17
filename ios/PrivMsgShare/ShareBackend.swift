import Foundation
import Security

struct SharedFile: Sendable {
    let url: URL
    let name: String
    let mimeType: String
    let size: Int64
}

struct ShareInput: Sendable {
    let files: [SharedFile]
    let text: String
}

enum ShareFailure: LocalizedError {
    case message(String)
    case signInRequired
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .signInRequired: return "Sign in to PrivMsg to send these items."
        }
    }
}

/// One operation keeps its document IDs across retry, including an uncertain
/// final response, so a retry cannot publish the same share twice.
final class ShareDraft: @unchecked Sendable {
    let messageID = "share-" + UUID().uuidString.lowercased()
    let files: [SharedFile]
    let fileKeys: [String]
    let text: String
    let threadID: String
    fileprivate var uploaded = Set<String>()
    fileprivate var commitAttempted = false
    fileprivate var committed = false

    init(files: [SharedFile], text: String, date: Date = Date()) {
        self.files = files
        fileKeys = files.map { _ in UUID().uuidString.lowercased() }
        self.text = text
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        threadID = "daily-" + formatter.string(from: date)
    }
}

private struct ShareCredential: Codable {
    let uid: String
    let refreshToken: String
}

private enum ShareKeychain {
    static let service = "PrivMsg.Share.Firebase"
    static let account = "rapp@local.mail"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() -> ShareCredential? {
        var values = query
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(values as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ShareCredential.self, from: data)
    }
    static func save(_ credential: ShareCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query
            values[kSecValueData as String] = data
            values[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else {
                throw ShareFailure.message("Could not securely remember the share-sheet sign-in.")
            }
        } else if status != errSecSuccess {
            throw ShareFailure.message("Could not securely remember the share-sheet sign-in.")
        }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

/// The share extension has its own sandbox and Keychain entry. It sends directly
/// to the existing Firebase backend, without App Groups or opening the host app.
actor ShareBackend {
    static let apiKey = "AIzaSyD3dBLNLnDdzURfor0B4v6hXuUb5LSr4zU"
    static let projectID = "privmsg-stream"
    static let email = "rapp@local.mail"
    static let chunkBytes = 512 * 1024
    static let documents = "https://firestore.googleapis.com/v1/projects/privmsg-stream/databases/(default)/documents"
    static let documentPrefix = "projects/privmsg-stream/databases/(default)/documents/drops/"
    private let session: URLSession
    private var credential: ShareCredential?
    private var idToken = ""
    private var expiresAt = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
        credential = ShareKeychain.read()
    }

    func restoreSignIn() async throws -> Bool {
        guard credential != nil else { return false }
        do { _ = try await validToken(); return true }
        catch ShareFailure.signInRequired { signOut(); return false }
    }

    func signIn(username: String, password: String) async throws {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["rapp", Self.email].contains(normalized), !password.isEmpty else {
            throw ShareFailure.message("Incorrect PrivMsg username or password.")
        }
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(Self.apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": Self.email, "password": password, "returnSecureToken": true])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["idToken"] as? String, let refresh = body["refreshToken"] as? String,
              let uid = body["localId"] as? String, body["email"] as? String == Self.email,
              !uid.isEmpty, !refresh.isEmpty, Self.allowedToken(token, uid: uid) else {
            throw ShareFailure.message("Could not sign in. Check your PrivMsg username and password, then try again.")
        }
        let saved = ShareCredential(uid: uid, refreshToken: refresh)
        try ShareKeychain.save(saved)
        credential = saved
        idToken = token
        expiresAt = Date().addingTimeInterval(TimeInterval(body["expiresIn"] as? String ?? "3600") ?? 3600)
    }

    func signOut() {
        credential = nil
        idToken = ""
        expiresAt = .distantPast
        ShareKeychain.clear()
    }

    private func validToken() async throws -> String {
        guard let saved = credential else { throw ShareFailure.signInRequired }
        if !idToken.isEmpty && expiresAt.timeIntervalSinceNow > 60 { return idToken }
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Self.apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var encoding = URLComponents()
        encoding.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: saved.refreshToken)]
        request.httpBody = Data((encoding.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShareFailure.message("Could not connect to PrivMsg.") }
        if [400, 401, 403].contains(http.statusCode) { signOut(); throw ShareFailure.signInRequired }
        guard http.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["id_token"] as? String, let uid = body["user_id"] as? String,
              let refresh = body["refresh_token"] as? String, uid == saved.uid,
              !refresh.isEmpty, Self.allowedToken(token, uid: uid) else {
            throw ShareFailure.message("Could not restore the share-sheet sign-in. Try again.")
        }
        let updated = ShareCredential(uid: uid, refreshToken: refresh)
        try ShareKeychain.save(updated)
        credential = updated
        idToken = token
        expiresAt = Date().addingTimeInterval(TimeInterval(body["expires_in"] as? String ?? "3600") ?? 3600)
        return token
    }

    // Tokens are received over Google's HTTPS API; this checks expected claims
    // in addition to that authenticated transport, without treating decoding as
    // independent signature verification.
    private static func allowedToken(_ token: String, uid: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              claims["sub"] as? String == uid, claims["aud"] as? String == projectID,
              claims["email"] as? String == email,
              (claims["firebase"] as? [String: Any])?["sign_in_provider"] as? String == "password" else { return false }
        return true
    }

    private func firestore(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                           allowMissing: Bool = false) async throws -> (Data, Int) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let token = try await validToken()
            var request = URLRequest(url: URL(string: Self.documents + path)!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ShareFailure.message("Could not reach PrivMsg.") }
            if http.statusCode == 401 && attempt == 0 { expiresAt = .distantPast; continue }
            if allowMissing && http.statusCode == 404 { return (data, 404) }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { throw ShareFailure.signInRequired }
                if http.statusCode == 403 { throw ShareFailure.message("Your PrivMsg account could not save this share. Sign in again or check access.") }
                if http.statusCode == 429 { throw ShareFailure.message("PrivMsg is receiving too many requests. Wait a moment, then retry.") }
                throw ShareFailure.message("PrivMsg could not save the share (server \(http.statusCode)). Retry to safely resume.")
            }
            return (data, http.statusCode)
        }
        throw ShareFailure.signInRequired
    }

    func send(_ draft: ShareDraft, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        _ = try await validToken()
        guard let uid = credential?.uid else { throw ShareFailure.signInRequired }
        if draft.committed { return }
        // Some owner-only rules deny reads of nonexistent documents. A first
        // send must not require that read; retries can probe opportunistically,
        // and exists:false below still prevents a duplicate publication.
        if draft.commitAttempted, (try? await messageAlreadySaved(draft, uid: uid)) == true {
            draft.committed = true
            return
        }
        let total = max(1, draft.files.reduce(Int64(0)) { $0 + $1.size })
        var completed: Int64 = 0
        var metadata: [[String: Any]] = []
        for (fileIndex, file) in draft.files.enumerated() {
            try Task.checkCancellation()
            let key = draft.fileKeys[fileIndex]
            let chunks = Int((file.size + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes))
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            for index in 0..<chunks {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: Self.chunkBytes) ?? Data()
                let expected = min(Int64(Self.chunkBytes), file.size - Int64(index * Self.chunkBytes))
                guard Int64(data.count) == expected else { throw ShareFailure.message("A shared file changed while it was being read. Share it again.") }
                let document = "chunk_\(key)_\(index)"
                if !draft.uploaded.contains(document) {
                    let fields = Self.chunkFields(data, key: key, index: index, owner: uid)
                    _ = try await firestore("/drops/\(document)", method: "PATCH", body: ["fields": fields])
                    draft.uploaded.insert(document)
                }
                completed += Int64(data.count)
                progress(Double(completed) / Double(total), "Uploading \(fileIndex + 1) of \(draft.files.count): \(file.name)")
            }
            guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw ShareFailure.message("A shared file changed size. Share it again.") }
            metadata.append(Self.attachmentFields(file, key: key, chunks: chunks))
        }
        try Task.checkCancellation()
        let fields = Self.messageFields(draft, metadata: metadata, owner: uid)
        let write: [String: Any] = ["update": ["name": Self.documentPrefix + draft.messageID, "fields": fields],
            "currentDocument": ["exists": false],
            "updateTransforms": [["fieldPath": "createdAt", "setToServerValue": "REQUEST_TIME"]]]
        draft.commitAttempted = true
        progress(1, "Saving to today's conversation…")
        do { _ = try await firestore(":commit", method: "POST", body: ["writes": [write]]) }
        catch {
            // If the response was lost, the fixed ID lets us confirm success.
            if (try? await messageAlreadySaved(draft, uid: uid)) != true { throw error }
        }
        draft.committed = true
    }

    private func messageAlreadySaved(_ draft: ShareDraft, uid: String) async throws -> Bool {
        let (data, status) = try await firestore("/drops/\(draft.messageID)", allowMissing: true)
        if status == 404 { return false }
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = document["fields"] as? [String: Any],
              (fields["owner"] as? [String: Any])?["stringValue"] as? String == uid,
              (fields["text"] as? [String: Any])?["stringValue"] as? String == draft.text,
              (fields["threadId"] as? [String: Any])?["stringValue"] as? String == draft.threadID,
              (fields["kind"] as? [String: Any])?["stringValue"] as? String == "drop" else {
            throw ShareFailure.message("Could not verify the previous share. Reopen the share sheet.")
        }
        let attachments = ((fields["attachments"] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]] ?? []
        let keys = attachments.compactMap { attachment -> String? in
            let metadata = (attachment["mapValue"] as? [String: Any])?["fields"] as? [String: Any]
            return (metadata?["key"] as? [String: Any])?["stringValue"] as? String
        }
        guard keys == draft.fileKeys else { throw ShareFailure.message("Could not verify the previous share's files. Reopen the share sheet.") }
        return true
    }

    /// Only cancel unpublished chunks. After a final commit was attempted its
    /// outcome may be uncertain, so deleting those chunks could corrupt a saved
    /// message. The same draft ID remains safe to retry instead.
    func discardUnpublished(_ draft: ShareDraft?) async {
        guard let draft, !draft.commitAttempted, !draft.committed, !idToken.isEmpty else { return }
        // Do not include never-written IDs: owner-only rules may reject deleting
        // a nonexistent document and thereby reject the entire atomic batch.
        let writes: [[String: Any]] = draft.uploaded.map { ["delete": Self.documentPrefix + $0] }
        guard !writes.isEmpty, writes.count <= 500 else { return }
        var request = URLRequest(url: URL(string: Self.documents + ":commit")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["writes": writes])
        _ = try? await session.data(for: request)
    }

    static func attachmentFields(_ file: SharedFile, key: String, chunks: Int) -> [String: Any] {
        let image = file.mimeType.hasPrefix("image/")
        return ["name": string(file.name), "type": string(file.mimeType), "size": integer(file.size),
                "category": string(image ? "image" : "file"), "key": string(key), "chunks": integer(Int64(chunks)),
                "encoding": string("base64-chunk-v1"), "downloadOnly": ["booleanValue": image && file.size >= 20 * 1024 * 1024]]
    }
    static func chunkFields(_ data: Data, key: String, index: Int, owner: String) -> [String: Any] {
        ["kind": string("chunk"), "key": string(key), "index": integer(Int64(index)),
         "data": string(data.base64EncodedString()), "encoding": string("base64-chunk-v1"), "owner": string(owner)]
    }
    static func messageFields(_ draft: ShareDraft, metadata: [[String: Any]], owner: String) -> [String: Any] {
        ["kind": string("drop"), "text": string(draft.text), "owner": string(owner), "threadId": string(draft.threadID),
         "attachments": ["arrayValue": ["values": metadata.map { ["mapValue": ["fields": $0]] }]]]
    }
    static func string(_ value: String) -> [String: Any] { ["stringValue": value] }
    static func integer(_ value: Int64) -> [String: Any] { ["integerValue": String(value)] }
}
