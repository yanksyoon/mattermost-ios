// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/files.ts (`uploadFile` → `POST /files`, `multipart/form-data` with the file
//        under `files` and the channel under `channel_id`), app/actions/remote/file.ts (the upload
//        queue: one request per file, progress from the transport, cancel by task id).
// Licence: Apache-2.0 — behaviour reimplemented against RFC 7578 and https://api.mattermost.com with
// attribution per docs/THIRD_PARTY_NOTICES.md §12; no upstream source copied.
//
// Why the body is built by hand rather than by `URLProtocol`/`URLSession` convenience:
//  - the encoder has to be a pure function so the byte layout can be asserted (delimiter placement,
//    the blank line between headers and content, the closing delimiter's trailing CRLF);
//  - and the *filename* is untrusted input on two axes at once. It reaches an HTTP header, so a
//    name containing `"`, CR or LF could inject a header or end the part early — this is a
//    server-visible request the app builds, and upstream's client has the same exposure. Every name
//    is reduced to a basename and stripped of characters that have meaning in a quoted-string.
//
// Layout (one file per request, like upstream):
//
//     --<boundary>\r\n
//     Content-Disposition: form-data; name="channel_id"\r\n
//     \r\n
//     <channel id>\r\n
//     --<boundary>\r\n
//     Content-Disposition: form-data; name="files"; filename="<name>"\r\n
//     Content-Type: <mime>\r\n
//     \r\n
//     <bytes>\r\n
//     --<boundary>--\r\n

import Foundation

enum MMMultipart {

    /// One text field of a multipart form.
    struct Field: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// One file of a multipart form.
    struct File: Equatable, Sendable {
        var fieldName: String
        var filename: String
        var mimeType: String
        var data: Data
    }

    /// A built body: the bytes and the `Content-Type` that goes with them.
    struct Encoded: Equatable, Sendable {
        var contentType: String
        var body: Data
    }

    /// Build the body. `boundary` is injectable so a test can assert exact bytes; production passes a
    /// random one (see `makeBoundary()`).
    static func encode(fields: [Field], files: [File], boundary: String) -> Encoded {
        var body = Data()
        for field in fields {
            append("--\(boundary)\r\n", to: &body)
            append("Content-Disposition: form-data; name=\"\(quoted(field.name))\"\r\n\r\n", to: &body)
            append(field.value, to: &body)
            append("\r\n", to: &body)
        }
        for file in files {
            append("--\(boundary)\r\n", to: &body)
            let name = sanitizedFilename(file.filename)
            append("Content-Disposition: form-data; name=\"\(quoted(file.fieldName))\"; "
                   + "filename=\"\(quoted(name))\"\r\n", to: &body)
            append("Content-Type: \(headerSafe(file.mimeType))\r\n\r\n", to: &body)
            body.append(file.data)
            append("\r\n", to: &body)
        }
        append("--\(boundary)--\r\n", to: &body)
        return Encoded(contentType: "multipart/form-data; boundary=\(boundary)", body: body)
    }

    /// A boundary that cannot occur in the payloads by accident: hex from `UUID`s, which also keeps it
    /// parseable by anything that logs the request.
    static func makeBoundary() -> String {
        "----MattermostIOSFormBoundary"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.prefix(8)
    }

    /// Reduce an arbitrary file name to something that is safe **and** unambiguous inside a
    /// `filename="…"` quoted-string:
    ///  - keep only the final path component (`../../etc/passwd` → `passwd`), so a name can never
    ///    suggest a path to the server or a reader of the request;
    ///  - drop `"`, `\`, CR, LF and NUL, any of which would end the quoted-string or the header line;
    ///  - collapse to `upload` when nothing usable remains.
    static func sanitizedFilename(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "\"\\\r\n\u{0}")
        name = name.components(separatedBy: forbidden).joined(separator: "_")
        // A leading dot would hide the file on a server that stores names as-is, and a name made only
        // of dots is not a name at all.
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "upload" : name
    }

    /// `Content-Type` comes from the picker, so it is validated rather than trusted: a value with a
    /// line break would split the header block.
    static func headerSafe(_ mimeType: String) -> String {
        let cleaned = mimeType
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "application/octet-stream" : cleaned
    }

    /// A best-effort type for a file the picker did not label.
    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "log", "md": return "text/plain"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: Private

    private static func append(_ text: String, to data: inout Data) {
        data.append(Data(text.utf8))
    }

    /// Quoted-string content: quotes and backslashes are the only characters with meaning inside
    /// `name="…"`; the CR/LF guard is the same one applied to the filename.
    private static func quoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
