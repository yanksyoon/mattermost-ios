// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/components/files/files.tsx`
// (images in a grid, everything else as a row), `app/components/files/image_file.tsx` (thumbnail vs
// overlay), `app/components/files/file.tsx` (row with type icon, name, size), `app/utils/message_attachment.ts`.
// Licence: Apache-2.0 — structure ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied. Layout numbers are this client's own and are stated where they are chosen.
//
// This file is **pure**: given a post's `PostAttachment`s it decides what the section draws (which
// attachments are images, which are rows, how big each grid cell is, which sheet a tap opens). No I/O,
// no SwiftUI, so every rule below is unit-testable and the row view has no branching of its own.

import Foundation
import CoreGraphics

// MARK: - Attachment → file type

extension PostAttachment {
    /// The file's type as the renderer sees it (extension first, then MIME type).
    var typeDescriptor: FileTypeDescriptor {
        FileTypeMap.descriptor(fileName: name, mimeType: mimeType, isBlocked: isBlocked)
    }

    var previewKind: FilePreviewKind { typeDescriptor.preview }

    /// "PDF", "PNG image", "CSV text" — the row's second line and its accessibility value.
    var typeLabel: String { FileTypeMap.typeLabel(typeDescriptor) }

    var symbolName: String { typeDescriptor.symbolName }

    /// True when the inline section may draw this attachment as a thumbnail. A file the server marked
    /// blocked, or a type this client refuses to decode (`image/svg+xml`), is a row instead — never an
    /// image load.
    var isInlineImage: Bool { previewKind == .image && !isBlocked }
}

// MARK: - What one post's attachment section draws

/// One post's attachments, split the way the section lays them out: images in a grid, everything else
/// as rows, each in the server's own order.
struct AttachmentSection: Equatable, Sendable {
    var images: [PostAttachment]
    var files: [PostAttachment]

    var isEmpty: Bool { images.isEmpty && files.isEmpty }

    init(_ attachments: [PostAttachment]) {
        images = attachments.filter { $0.isInlineImage }
        files = attachments.filter { !$0.isInlineImage }
    }
}

/// The full-screen gallery for one post: every image it carries, in order, so paging can move between
/// them and the counter can say "3 of 10".
struct AttachmentGallery: Identifiable, Equatable, Sendable {
    let postID: String
    let images: [PostAttachment]

    var id: String { postID }

    init?(postID: String, attachments: [PostAttachment]) {
        let images = attachments.filter { $0.isInlineImage }
        guard !images.isEmpty else { return nil }
        self.postID = postID
        self.images = images
    }

    func index(of fileID: String) -> Int? {
        images.firstIndex { $0.id == fileID }
    }

    /// "3 of 10" — the gallery's own counter, drawn as text and exposed to VoiceOver.
    func counterLabel(_ index: Int) -> String {
        "\(index + 1) of \(images.count)"
    }
}

// MARK: - Inline image grid

/// How an image grid is drawn. One image gets the full bubble width (up to a cap), two or three share
/// a row, four or more become a square-ish 3-column grid — the same progression the web app uses, with
/// this client's numbers:
///
///  * one image: at most 300 × 240 pt, aspect preserved;
///  * 2–3 images: equal squares of `rowCell` (104 pt), so a row of three fits a 375 pt bubble;
///  * 4+: 3 columns of `gridCell` (96 pt), rows of three.
///
/// The numbers exist to bound memory as much as to look right: a cell is decoded from the server's
/// thumbnail, and the viewer asks for the original only when the reader opens one.
enum AttachmentImageGrid {
    static let singleMaxWidth: CGFloat = 300
    static let singleMaxHeight: CGFloat = 240
    static let rowCell: CGFloat = 104
    static let gridCell: CGFloat = 96
    static let spacing: CGFloat = 4
    /// Images drawn inline before the layout switches to the compact grid. Not a cap on what is drawn
    /// — every image is drawn — but the point at which cells stop growing.
    static let compactThreshold = 4

    /// Columns for a count. 0 for an empty list (nothing to lay out).
    static func columnCount(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        if count <= 3 { return count }
        return 3
    }

    /// The cell size for one image in a grid of `count`, given the width the bubble offers.
    /// A single image keeps its own aspect ratio (the view draws `scaledToFit` inside these bounds);
    /// every other cell is square.
    static func cellSize(count: Int, availableWidth: CGFloat = 300) -> CGSize {
        guard count > 0 else { return .zero }
        if count == 1 {
            return CGSize(width: min(singleMaxWidth, max(60, availableWidth)),
                          height: singleMaxHeight)
        }
        let side = count < compactThreshold ? rowCell : gridCell
        let columns = CGFloat(columnCount(for: count))
        // Never overflow the width the parent actually offers (a narrow split-view column).
        let maxSide = (availableWidth - spacing * (columns - 1)) / columns
        let bounded = max(44, min(side, maxSide))
        return CGSize(width: bounded, height: bounded)
    }

    /// How many rows the grid needs (for a container that wants to reserve height).
    static func rowCount(for count: Int) -> Int {
        let columns = columnCount(for: count)
        guard columns > 0 else { return 0 }
        return Int((Double(count) / Double(columns)).rounded(.up))
    }
}

// MARK: - Downloads

/// What a row says about a file it can save. Mirrors `DownloadState` but is the row's own vocabulary:
/// a row only cares that it is not started, running, landed or failed, and it needs a label.
enum AttachmentDownloadState: Equatable, Sendable {
    case idle
    /// `fraction` is nil until the server has said how large the file is.
    case downloading(fraction: Double?)
    case done
    case failed(String)

    var isActive: Bool {
        switch self {
        case .downloading: return true
        default: return false
        }
    }

    /// The row's second line: type · size · status.
    var label: String {
        switch self {
        case .idle: return ""
        case .downloading(let fraction):
            if let fraction { return "Downloading \(Int((fraction * 100).rounded()))%" }
            return "Downloading…"
        case .done: return "Saved to Downloads"
        case .failed(let reason): return "Download failed\(reason.isEmpty ? "" : ": \(reason)")"
        }
    }

    /// The status shown after the size, or "" when the file is simply there.
    static func from(_ state: DownloadState?, received: Int64, total: Int64) -> AttachmentDownloadState {
        switch state {
        case .some(.downloading):
            return .downloading(fraction: total > 0 ? Double(received) / Double(total) : nil)
        case .some(.done): return .done
        case .some(.cancelled): return .idle
        case .some(.waitToRetry), .some(.error): return .failed("")
        case .none: return .idle
        }
    }
}

// MARK: - Sheet targets

/// A file opened on its own: the PDF/text/unsupported preview. Carries the post id so the sheet's
/// identifiers stay stable (`post.<id>.attachment.<fileID>`) and the row keeps its own name for the
/// title bar.
struct AttachmentPreviewTarget: Identifiable, Equatable, Sendable {
    let postID: String
    let attachment: PostAttachment

    var id: String { "\(postID)/\(attachment.id)" }
}

/// The gallery, addressed to one page. `Identifiable` for `.sheet(item:)`, and `gallery` is derived
/// from the row's own attachments so the sheet cannot show a different set than the row did.
struct AttachmentGalleryTarget: Identifiable, Equatable, Sendable {
    let postID: String
    let attachments: [PostAttachment]
    let startFileID: String

    var id: String { "\(postID)/\(startFileID)" }

    var gallery: AttachmentGallery? {
        AttachmentGallery(postID: postID, attachments: attachments)
    }

    var startIndex: Int {
        gallery?.index(of: startFileID) ?? 0
    }
}
