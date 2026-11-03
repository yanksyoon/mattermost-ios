// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_files/ (the channel's files list: name, type, size, paging),
//        app/client/rest/files.ts (`searchFiles` → `POST /teams/{team_id}/files/search`),
//        app/components/files/file.tsx (the row this list reuses through T38's `PostAttachment`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied.
//
// **Which route answers "this channel's files" — measured, not assumed** (docs/t52-build-note.md §2):
//
//   * `GET /channels/{id}/files` → **404** `api.context.404.app_error` (no such route on 9.11.19);
//   * `POST /teams/{tid}/files/search` with `terms: "in:<channel-name>"` → 200 with
//     `{order, file_infos, next_file_info_id, …}`, and its set agrees exactly with the file ids in the
//     channel's own posts (measured: 16/16 and 40/40 on `t38-files` and `t38-av-heavy`);
//   * `terms: "channel_id:<id>"` → 200 with **nothing** (that operator is not this server's filter);
//   * the same search with an **empty** `terms` → 400 `Invalid or missing terms in request body`;
//   * a direct/group message's `name` is an opaque hash and `in:<hash>` finds nothing even when the GM
//     holds a file (measured on a scratch GM: `stats.files_count` 1, search 0) — which is why the
//     channel-info Files row is offered for `O`/`P` channels only. A row that always says "no files"
//     for a conversation that has one would be a lie.
//
// The server ignored `per_page` on this fixture and answered every match in one page with an empty
// `next_file_info_id` (measured with per_page 2/5/10/20). The client still sends it and still follows
// the cursor: a server that does page must be followed, and one that does not simply never sets it.
//
// This file is pure: the wire shape (tolerantly decoded), the row derivation and the paging rule, so
// each is unit-testable without a server.

import Foundation
import UniformTypeIdentifiers

// MARK: - Wire shape

/// `POST /teams/{tid}/files/search`'s answer, for a channel-filtered search.
///
/// `file_infos` is a **map keyed by file id** (not an array) on 9.11.19, and `order` is the server's
/// own ordering of those ids. A file this build cannot read is dropped rather than drawn as a blank
/// row — the alternative is a row whose name is an id.
struct ChannelFileSearchResult: Decodable, Equatable, Sendable {
    var order: [String]
    var fileInfos: [String: ChannelFileInfo]
    var nextFileInfoID: String

    enum CodingKeys: String, CodingKey {
        case order
        case fileInfos = "file_infos"
        case nextFileInfoID = "next_file_info_id"
    }

    init(order: [String] = [], fileInfos: [String: ChannelFileInfo] = [:], nextFileInfoID: String = "") {
        self.order = order
        self.fileInfos = fileInfos
        self.nextFileInfoID = nextFileInfoID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        nextFileInfoID = (try? container.decodeIfPresent(String.self, forKey: .nextFileInfoID)) ?? ""
        // Tolerant on purpose: one unreadable file info must not fail the whole page. `decodeIfPresent`
        // on a dictionary is all-or-nothing, so each value is decoded on its own.
        var infos: [String: ChannelFileInfo] = [:]
        if let raw = try? container.decodeIfPresent([String: MMRawJSON].self, forKey: .fileInfos) {
            for (key, value) in raw {
                if let info = try? value.decode(ChannelFileInfo.self), !info.id.isEmpty {
                    infos[key] = info
                }
            }
        }
        fileInfos = infos
    }
}

/// One file as the channel-files list needs it.
///
/// Deliberately **not** `MMFileInfo`: that model requires `width`/`height`/`mime_type`, and a text
/// file's `files/search` row carries none of them (measured). Decoding it would drop every non-image
/// from the list. Only the fields this list draws, plus `create_at` for the fallback ordering.
struct ChannelFileInfo: Decodable, Equatable, Sendable {
    var id: String
    var postID: String
    var name: String
    var fileExtension: String
    var mimeType: String
    var size: Int64
    var createAt: Int64
    var isBlocked: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case postID = "post_id"
        case fileExtension = "extension"
        case mimeType = "mime_type"
        case createAt = "create_at"
        case isBlocked = "is_blocked"
    }

    init(id: String,
         postID: String = "",
         name: String = "",
         fileExtension: String = "",
         mimeType: String = "",
         size: Int64 = 0,
         createAt: Int64 = 0,
         isBlocked: Bool = false) {
        self.id = id
        self.postID = postID
        self.name = name
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.size = size
        self.createAt = createAt
        self.isBlocked = isBlocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        postID = (try? container.decodeIfPresent(String.self, forKey: .postID)) ?? ""
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        fileExtension = (try? container.decodeIfPresent(String.self, forKey: .fileExtension)) ?? ""
        mimeType = (try? container.decodeIfPresent(String.self, forKey: .mimeType)) ?? ""
        size = (try? container.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        createAt = (try? container.decodeIfPresent(Int64.self, forKey: .createAt)) ?? 0
        isBlocked = (try? container.decodeIfPresent(Bool.self, forKey: .isBlocked)) ?? false
    }

    /// A MIME type the server left empty is inferred from the extension, so the row's icon and the
    /// preview decision are not "unknown type" for a `.txt` the server forgot to label.
    var resolvedMIMEType: String {
        if !mimeType.isEmpty { return mimeType }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? ""
    }
}

// MARK: - Rows

/// One file in the channel-files list. Wraps T38's `PostAttachment` so the row, the preview and the
/// gallery are the same code that post attachments already use (one file renderer, not two).
struct ChannelFileRow: Identifiable, Equatable, Sendable {
    var id: String
    var postID: String
    var attachment: PostAttachment

    var isInlineImage: Bool { attachment.isInlineImage }
}

enum ChannelFileDerivation {

    /// Turn one page into rows: the server's `order` first, then anything it sent without naming (a
    /// file the order array forgot) newest first, then by name — deterministic, and never a file the
    /// server did not send.
    static func rows(from result: ChannelFileSearchResult) -> [ChannelFileRow] {
        var seen = Set<String>()
        var ordered: [ChannelFileInfo] = []
        for id in result.order {
            guard let info = result.fileInfos[id], seen.insert(id).inserted else { continue }
            ordered.append(info)
        }
        let remainder = result.fileInfos.values
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.createAt != rhs.createAt { return lhs.createAt > rhs.createAt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        ordered.append(contentsOf: remainder)
        return ordered.map { info in
            let mime = info.resolvedMIMEType
            let kind = PostAttachment.kind(forMimeType: mime)
            let attachment = PostAttachment(id: info.id,
                                            name: info.name.isEmpty ? info.id : info.name,
                                            mimeType: mime,
                                            sizeBytes: info.size,
                                            kind: kind,
                                            isBlocked: info.isBlocked,
                                            hasThumbnail: kind == .image && !info.isBlocked)
            return ChannelFileRow(id: info.id, postID: info.postID, attachment: attachment)
        }
    }

    /// Whether a further page exists. The cursor is the server's; a cursor that repeats the last file
    /// it already sent is treated as the end (a server bug must not become an infinite scroll).
    static func hasMore(after result: ChannelFileSearchResult) -> Bool {
        let cursor = result.nextFileInfoID
        guard !cursor.isEmpty else { return false }
        return !result.fileInfos.keys.contains(cursor)
    }
}
