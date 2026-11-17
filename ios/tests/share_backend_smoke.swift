import Foundation

@main
struct ShareBackendSmoke {
    static func main() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "ShareBackendSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func string(_ fields: [String: Any], _ key: String) -> String? {
            (fields[key] as? [String: Any])?["stringValue"] as? String
        }
        func integer(_ fields: [String: Any], _ key: String) -> Int64? {
            ((fields[key] as? [String: Any])?["integerValue"] as? String).flatMap(Int64.init)
        }
        // Binary data crosses a chunk boundary. Round-trip through exactly the
        // Firestore JSON representation used by the existing web downloader.
        let bytes = Data((0..<(ShareBackend.chunkBytes + 19)).map { UInt8($0 % 256) })
        var reconstructed = Data()
        for (index, offset) in stride(from: 0, to: bytes.count, by: ShareBackend.chunkBytes).enumerated() {
            let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + ShareBackend.chunkBytes))
            let fields = ShareBackend.chunkFields(chunk, key: "original-key", index: index, owner: "test-owner")
            let json = try JSONSerialization.data(withJSONObject: ["fields": fields])
            try expect(json.count < 1_048_576, "A binary chunk must fit Firestore's document size limit")
            let document = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            let decoded = document["fields"] as! [String: Any]
            try expect(string(decoded, "kind") == "chunk", "Incorrect chunk kind")
            try expect(string(decoded, "encoding") == "base64-chunk-v1", "Encoding must match web downloader")
            try expect(string(decoded, "key") == "original-key", "File key changed")
            try expect(string(decoded, "owner") == "test-owner", "Missing chunk owner")
            try expect(integer(decoded, "index") == Int64(index), "Chunk order changed")
            reconstructed.append(Data(base64Encoded: string(decoded, "data")!)!)
        }
        try expect(reconstructed == bytes, "Original binary bytes were changed")

        let pdf = SharedFile(url: URL(fileURLWithPath: "/unused/test.pdf"), name: "Résumé.pdf", mimeType: "application/pdf", size: Int64(bytes.count))
        let image = SharedFile(url: URL(fileURLWithPath: "/unused/large.png"), name: "large.png", mimeType: "image/png", size: 21 * 1024 * 1024)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
        let draft = ShareDraft(files: [pdf, image], text: "Original files", date: date)
        try expect(draft.threadID == "daily-2026-11-17", "Share must use today's existing daily-thread format")
        try expect(Set(draft.fileKeys).count == 2, "Each original requires its own key")
        let firstID = draft.messageID
        let metadata = [ShareBackend.attachmentFields(pdf, key: draft.fileKeys[0], chunks: 2),
                        ShareBackend.attachmentFields(image, key: draft.fileKeys[1], chunks: 42)]
        try expect(string(metadata[0], "name") == "Résumé.pdf", "Original filename lost")
        try expect(string(metadata[0], "type") == "application/pdf", "MIME type lost")
        try expect(string(metadata[0], "category") == "file", "PDF must remain a file")
        try expect(integer(metadata[0], "chunks") == 2, "Wrong chunk count")
        try expect(integer(metadata[0], "size") == Int64(bytes.count), "Wrong original size")
        try expect(string(metadata[1], "category") == "image", "Image category lost")
        try expect((metadata[1]["downloadOnly"] as? [String: Any])?["booleanValue"] as? Bool == true, "Large images must avoid eager decoding")
        let fields = ShareBackend.messageFields(draft, metadata: metadata, owner: "test-owner")
        try expect(string(fields, "kind") == "drop", "Message kind must match timeline query")
        try expect(string(fields, "threadId") == draft.threadID, "Message destination changed")
        try expect(string(fields, "owner") == "test-owner", "Message owner missing")
        let attachments = ((fields["attachments"] as! [String: Any])["arrayValue"] as! [String: Any])["values"] as! [[String: Any]]
        try expect(attachments.count == 2, "Message must include every original")
        _ = try JSONSerialization.data(withJSONObject: ["fields": fields])
        try expect(draft.messageID == firstID, "A retry must keep the same message identity")
        let textOnly = ShareDraft(files: [], text: "https://example.com/file", date: date)
        let link = ShareBackend.messageFields(textOnly, metadata: [], owner: "test-owner")
        try expect(string(link, "text") == "https://example.com/file", "A remote URL must stay text")
        print("Share backend smoke passed: binary integrity, wire schema, original metadata, daily destination, retry identity, and text links")
    }
}
