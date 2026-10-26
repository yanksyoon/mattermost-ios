// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/utils/file/file_icon.tsx (document type → icon), app/utils/file/index.ts
//        (isDocument/getFileType/isSupportedExtension), app/components/files/file.tsx (the
//        previewable / not-previewable split), app/components/files/document_file.tsx.
// Licence: Apache-2.0 — the classification is reimplemented in Swift with attribution per
// docs/THIRD_PARTY_NOTICES.md §15; no upstream source copied.
//
// Why a table and not "mimeType.hasPrefix(\"image\")": a Mattermost file arrives with whatever the
// uploader's browser said (`mime_type`), and that field is *attacker-controlled input* — a `.html`
// uploaded as `image/png` must not be decoded as an image, and an `image/svg+xml` is a document that
// can script. Classification therefore looks at the **name's extension first**, the MIME type second,
// and both are only ever used to pick a *renderer*, never to decide what may execute. Nothing here
// hands bytes to a web view, a JavaScript context, or the system's document interpreter: the readers
// are `UIImage` (images), `PDFKit` (PDF) and a plain `Text` view (text). Everything else is drawn as
// a row with an icon, a size and a download button — see `FilePreviewView`.

import Foundation

/// What kind of thing a file is. Used for the icon and for which reader (if any) may open it.
enum FileCategory: String, Equatable, Sendable, CaseIterable {
    case image
    case pdf
    case audio
    case video
    case archive
    case spreadsheet
    case document
    case presentation
    case code
    case text
    case other

    /// SF Symbol for the row. Kept here (not in the view) so the mapping is unit-testable and a
    /// category can never be added without an icon.
    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "video"
        case .archive: return "archivebox"
        case .spreadsheet: return "tablecells"
        case .document: return "doc.text"
        case .presentation: return "rectangle.on.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .other: return "doc"
        }
    }
}

/// Which reader, if any, draws a file's bytes.
enum FilePreviewKind: Equatable, Sendable {
    /// `UIImage` in the full-screen gallery (zoom + paging).
    case image
    /// `PDFKit`'s `PDFView` — a real PDF parser, never a web view.
    case pdf
    /// Plain, non-interpreted text with a byte cap (`FileTypeMap.textPreviewByteLimit`).
    case text
    /// No reader. The file can still be downloaded and shared, but its bytes are never interpreted.
    case unsupported(UnsupportedReason)

    enum UnsupportedReason: String, Equatable, Sendable {
        /// A type this client deliberately refuses to render (see `FileTypeMap.unsafeExtensions`).
        case unsafe
        /// A perfectly ordinary type that simply has no native reader yet (zip, xlsx, docx, video).
        case noReader
        /// The server marked the file as blocked for this client.
        case blocked
    }

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

/// Everything the UI needs to know about one file's name, without touching its bytes.
struct FileTypeDescriptor: Equatable, Sendable {
    var category: FileCategory
    /// Lower-cased extension without the dot ("" when the name has none).
    var fileExtension: String
    var preview: FilePreviewKind

    var symbolName: String { category.symbolName }
}

enum FileTypeMap {

    /// The largest file this client will decode as text. A 200 MB log is not a preview, and reading
    /// it whole is the difference between a bounded screen and an unbounded allocation.
    static let textPreviewByteLimit = 256 * 1024

    /// The largest image the gallery will decode at full size. Anything bigger is drawn from the
    /// server's thumbnail instead, and the viewer says so — never silently downsampled to nothing.
    static let imageDecodeByteLimit = 24 * 1024 * 1024

    // MARK: Extensions

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff", "ico",
    ]
    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "csv", "tsv", "json", "yaml", "yml", "toml", "ini",
        "conf", "cfg", "env", "properties", "sql", "diff", "patch", "rst", "adoc", "tex",
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "go", "rs",
        "rb", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "php", "pl", "lua", "r", "scala",
        "clj", "ex", "exs", "dart", "vue", "svelte", "css", "scss", "sass", "less", "sh", "bash",
        "zsh", "fish", "ps1", "bat", "cmd", "gradle", "groovy", "makefile", "dockerfile",
    ]
    private static let spreadsheetExtensions: Set<String> = ["xls", "xlsx", "xlsm", "numbers", "ods"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "pages", "odt", "rtf"]
    private static let presentationExtensions: Set<String> = ["ppt", "pptx", "key", "odp"]
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso",
    ]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "mpg", "mpeg"]

    /// Extensions whose bytes are **never** interpreted by this client, whatever the MIME type says.
    ///
    /// These are documents that a renderer would *execute* (HTML/SVG/XML with a stylesheet), files the
    /// OS would hand to an interpreter (`.command`, `.app`, `.pkg`, `.mobileconfig`) and binaries. The
    /// row still names the file, states its type and offers Download — the one thing it must never do
    /// is open it in something that runs it.
    ///
    /// Source code (`.js`, `.py`, `.sh`, …) is **not** in this set: it is read as plain text by the
    /// text reader, which never evaluates it. That distinction is the point of the set — "unsafe" means
    /// "a renderer could act on this", not "a developer would recognise this".
    static let unsafeExtensions: Set<String> = [
        "html", "htm", "xhtml", "xht", "shtml", "svg", "svgz", "xml", "xsl", "xslt", "wasm",
        "app", "exe", "msi", "com", "scr", "vbs", "jse", "wsf", "hta", "swf", "jar", "pkg",
        "command", "tool", "terminal", "mobileconfig", "mobileprovision", "scpt", "applescript",
        "webloc", "url", "desktop", "cgi", "asp", "aspx", "jsp",
    ]

    /// MIME types whose bytes are **never** interpreted (the same rule as `unsafeExtensions`,
    /// applied when the file name is useless).
    ///
    /// Only *documents a renderer would act on* are listed: markup (HTML/XHTML/XML/SVG), installers
    /// and executables, disk images, and form-encoded URLs. Script **text** (`application/x-sh`,
    /// `application/javascript`) is deliberately **not** here — this client only ever shows it as
    /// characters in a `Text` view, so refusing it would lose a readable file for no safety gain:
    /// there is no interpreter on the path.
    static let unsafeMimeTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml", "text/xml", "application/xml",
        "application/x-executable", "application/x-msdownload",
        "application/x-apple-diskimage", "application/x-command", "application/x-shockwave-flash",
        "application/java-archive", "application/x-www-form-urlencoded",
    ]

    /// Files a corporate server may ask a client to open. Treated as unsafe *content* here: the row
    /// says so instead of offering a preview. (Mattermost's own `file_filter.tsx` hides some file
    /// types entirely; this client keeps the file visible and refuses only the preview, so the reader
    /// can still download what they were sent.)
    static let unsafeMimePrefixes = ["text/html", "image/svg"]

    // MARK: Classification

    /// The extension this client acts on: the name's own, lower-cased. A name with no dot yields
    /// `""` so the MIME type decides. A dotfile's whole suffix is treated as its extension
    /// (`.env` → `env`), which is what makes a `.env` readable as text instead of falling through to
    /// whatever MIME type the uploader's browser guessed.
    static func fileExtension(of fileName: String) -> String {
        let base = fileName.split(separator: "/").last.map(String.init) ?? fileName
        guard let dot = base.lastIndex(of: "."), dot < base.index(before: base.endIndex) else {
            return ""
        }
        return base[base.index(after: dot)...].lowercased()
    }

    /// Classify one file. `mimeType` is only consulted when the extension is unknown, and an
    /// extension that contradicts a dangerous MIME type wins: `danger.png` served as `text/html` is
    /// still refused, because the *server's* claim is not the safer of the two.
    static func descriptor(fileName: String, mimeType: String, isBlocked: Bool = false) -> FileTypeDescriptor {
        let ext = fileExtension(of: fileName)
        let mime = mimeType.lowercased()
        let category = category(fileExtension: ext, mimeType: mime)

        if isBlocked {
            return FileTypeDescriptor(category: category, fileExtension: ext, preview: .unsupported(.blocked))
        }
        if unsafeExtensions.contains(ext) || unsafeMimeTypes.contains(mime)
            || unsafeMimePrefixes.contains(where: { mime.hasPrefix($0) }) {
            return FileTypeDescriptor(category: category, fileExtension: ext, preview: .unsupported(.unsafe))
        }
        switch category {
        case .image:
            return FileTypeDescriptor(category: .image, fileExtension: ext, preview: .image)
        case .pdf:
            return FileTypeDescriptor(category: .pdf, fileExtension: ext, preview: .pdf)
        case .text, .code:
            return FileTypeDescriptor(category: category, fileExtension: ext, preview: .text)
        default:
            return FileTypeDescriptor(category: category, fileExtension: ext, preview: .unsupported(.noReader))
        }
    }

    static func category(fileExtension ext: String, mimeType: String) -> FileCategory {
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if textExtensions.contains(ext) { return .text }
        if codeExtensions.contains(ext) { return .code }
        if spreadsheetExtensions.contains(ext) { return .spreadsheet }
        if documentExtensions.contains(ext) { return .document }
        if presentationExtensions.contains(ext) { return .presentation }
        if archiveExtensions.contains(ext) { return .archive }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        // No usable extension: the server's MIME type is the only remaining signal.
        if mimeType.hasPrefix("image/svg") { return .image }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType == "application/pdf" { return .pdf }
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("text/") { return .text }
        if mimeType.contains("zip") || mimeType.contains("compressed") || mimeType.contains("tar") {
            return .archive
        }
        if mimeType.contains("spreadsheet") || mimeType.contains("excel") || mimeType.contains("csv") {
            return .spreadsheet
        }
        if mimeType.contains("presentation") || mimeType.contains("powerpoint") { return .presentation }
        if mimeType.contains("word") || mimeType.contains("opendocument.text") { return .document }
        return .other
    }

    /// A human label for a file's type, for the row's second line and the reader's accessibility
    /// value ("PDF", "PNG image", "text"). Falls back to the raw extension, upper-cased, so an
    /// unknown type is named rather than guessed at.
    static func typeLabel(_ descriptor: FileTypeDescriptor) -> String {
        switch descriptor.category {
        case .image: return descriptor.fileExtension.isEmpty ? "Image" : "\(descriptor.fileExtension.uppercased()) image"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .video: return "Video"
        case .archive: return "Archive"
        case .spreadsheet: return "Spreadsheet"
        case .document: return "Document"
        case .presentation: return "Presentation"
        case .code: return descriptor.fileExtension.isEmpty ? "Source code" : "\(descriptor.fileExtension.uppercased()) source"
        case .text: return descriptor.fileExtension.isEmpty ? "Text" : "\(descriptor.fileExtension.uppercased()) text"
        case .other:
            return descriptor.fileExtension.isEmpty ? "File" : "\(descriptor.fileExtension.uppercased()) file"
        }
    }

    /// What the reader is told when a file cannot be previewed. One sentence, and it never implies
    /// the file was opened.
    static func unsupportedReason(_ reason: FilePreviewKind.UnsupportedReason) -> String {
        switch reason {
        case .unsafe:
            return "This file type is not previewed for safety. Download it to open it in another app."
        case .noReader:
            return "There is no preview for this file type yet. Download it to open it in another app."
        case .blocked:
            return "The server blocked this file. It cannot be previewed or downloaded from this client."
        }
    }
}
