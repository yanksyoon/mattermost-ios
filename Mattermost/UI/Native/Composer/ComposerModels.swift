// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/autocomplete/autocomplete.tsx (which source is active and what a selection
//        replaces), app/components/autocomplete/at_mention/at_mention.tsx (the `@` token),
//        channel_mention/channel_mention.tsx (typing `#`, inserting `~channel-name`),
//        emoji_suggestion/emoji_suggestion.tsx (the `:name:` token and its closing colon),
//        app/components/post_draft/draft_input/draft_input.tsx (the markdown toolbar:
//        bold/italic/strike/code/link/quote/list over the current selection),
//        app/screens/edit_post/edit_post.tsx (edit mode keeps the post id, not the draft),
//        app/utils/post_list/index.ts (a pending post is shown optimistically, then replaced).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
// upstream source copied. Everything in this file is pure (no I/O, no main actor, no SwiftUI), so the
// rules are unit-testable exactly as written (docs/component-map.md §4 "logic-first").
//
// Why the trigger parser lives here and not in the view:
//  - the caret is a UTF-16 offset into an NSAttributedString-backed `UITextView`, and every bug in
//    this area is an off-by-one at a boundary (start of text, after a newline, inside `href`, after a
//    closing colon). A pure function over (text, caret) is the only way to pin those boundaries;
//  - the *insertion* is a separate decision from the *match*: Mattermost's channel suggestion is
//    triggered by `#` but inserted as `~name`, and an emoji is inserted as `:name:`. Keeping the two
//    apart is what stops that mapping from being re-derived (and re-broken) in three places.

import Foundation

// MARK: - Suggestions

/// One row of the autocomplete list, with everything the view and the insertion need.
struct ComposerSuggestion: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case user
        case channel
        /// `@channel`, `@here`, `@all` — a mention that addresses people rather than matching them.
        case specialMention
        /// A `:name:` shortcode, built in or owned by the server.
        case emoji
    }

    var kind: Kind
    /// The bare value: a username, a channel name, an emoji name, or `channel`/`here`/`all`.
    var value: String
    /// The primary line ("Kim Park", "#town-square", "🎉 tada").
    var label: String
    /// The secondary line the list draws ("@kim.park · online", "Public channel").
    var detail: String
    /// What typing the name inserts, without the trailing space (added by the caller when the caret
    /// is not already followed by whitespace).
    var insertion: String
    /// A glyph for a built-in emoji; `nil` for users and channels (the row draws an initial).
    var glyph: String?
    /// The server id behind this row, when it has one.
    ///
    /// The membership check needs it and cannot use `value`: the channel's member list is a set of
    /// **user ids**, while `value` is the username that gets typed. Comparing the two would silently
    /// drop every suggestion (T35: caught by `testMentionsAreFilteredToTheChannelsMembers`).
    var userID: String? = nil

    var id: String { "\(kind.rawValue)-\(value)" }
}

/// How a user mention is inserted: `@username`.
func mentionInsertion(_ username: String) -> String { "@\(username)" }
/// How a channel mention is inserted: Mattermost's channel-link syntax is `~name`, even though the
/// trigger is `#` (upstream `channel_mention.tsx` inserts the tilde form).
func channelInsertion(_ name: String) -> String { "~\(name.replacingOccurrences(of: " ", with: "-"))" }
/// How an emoji is inserted: `:name:`.
func emojiInsertion(_ name: String) -> String { ":\(name):" }

// MARK: - Triggers

/// What the caret is currently asking for, and exactly which characters a selection replaces.
struct ComposerTrigger: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case mention
        case channel
        case emoji
    }

    var kind: Kind
    /// The text after the sigil (`@pe` → `pe`). May be empty: a bare `@` is a valid trigger.
    var term: String
    /// UTF-16 range of the sigil *and* the term — the characters an insertion replaces.
    var range: NSRange

    /// Number of characters the caller should put back after inserting a value, so the next word can
    /// be completed without the user typing a space.
    ///
    /// The caret here is the *end* of the trigger, i.e. an offset between 0 and `text.length`
    /// inclusive, so the character lookup is only valid below `length`: a caret at the end has
    /// nothing after it and gets the separating space.
    static func trailingSpace(after caret: Int, in text: String) -> String {
        let ns = text as NSString
        guard caret > 0, caret < ns.length else { return " " }
        let next = ns.character(at: caret)
        // Already separated (or at a hard boundary): do not add a second space.
        if next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D { return "" }
        return " "
    }
}

/// The pure trigger rules.
///
/// A trigger is the run of non-whitespace immediately before the caret, and only when it *starts*
/// with the sigil. That single rule gives the behaviour Mattermost has and the cases its bug reports
/// are about:
///
///  * `@kim` types → mention; `email@example.com` → nothing (the sigil is not the word's first char);
///  * `:smile` → emoji; `:smile:` (closed) → nothing, because a completed shortcode is a word, not a
///    query — the list must not reappear behind the caret while the user keeps typing;
///  * `#town` → channel; `##` and a markdown heading `# heading` → nothing (the term starts with the
///    sigil too, which is why the term itself may not include it);
///  * a caret that sits right after whitespace, or at offset 0, has no trigger.
enum ComposerTriggerParser {

    static func trigger(in text: String, caret: Int) -> ComposerTrigger? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length, caret > 0 else { return nil }

        var start = caret
        while start > 0 {
            let character = ns.character(at: start - 1)
            if isWhitespace(character) { break }
            start -= 1
        }
        guard start < caret else { return nil }

        let word = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let sigil = word.first else { return nil }
        let term = String(word.dropFirst())

        let kind: ComposerTrigger.Kind
        switch sigil {
        case "@":
            kind = .mention
            // A second sigil means this is not a mention the user is typing (`@@`, `@a@b`).
            if term.contains("@") { return nil }
        case "#":
            kind = .channel
            if term.contains("#") { return nil }
        case ":":
            kind = .emoji
            // A closed shortcode (`:smile:`) is finished text, and an emoji name has no colon in it.
            if term.contains(":") { return nil }
        default:
            return nil
        }

        return ComposerTrigger(kind: kind, term: term,
                               range: NSRange(location: start, length: caret - start))
    }

    /// Apply a chosen suggestion: replace the trigger with its insertion text (plus a separating space
    /// when the caret is not already followed by whitespace) and report the new caret.
    ///
    /// Returns `nil` when the trigger no longer fits the text (the caller has moved on since the list
    /// was drawn) — the edit is then dropped rather than applied at the wrong offset, which is the
    /// failure mode of "insert at the index the list remembers".
    static func apply(_ suggestion: ComposerSuggestion,
                      to text: String,
                      trigger: ComposerTrigger) -> (text: String, caret: Int)? {
        let ns = text as NSString
        guard trigger.range.location >= 0,
              trigger.range.location + trigger.range.length <= ns.length else { return nil }
        let end = trigger.range.location + trigger.range.length
        let space = ComposerTrigger.trailingSpace(after: end, in: text)
        let replacement = suggestion.insertion + space
        let updated = ns.replacingCharacters(in: trigger.range, with: replacement)
        return (updated, trigger.range.location + (replacement as NSString).length)
    }

    static func isWhitespace(_ character: unichar) -> Bool {
        // `\n`, `\r`, `\t`, space, and the non-breaking space a paste from a web page brings.
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
            || character == 0xA0
    }
}

// MARK: - Markdown toolbar

/// The formatting buttons the composer's toolbar offers.
enum ComposerMarkdownAction: String, CaseIterable, Sendable {
    case bold
    case italic
    case strikethrough
    case code
    case link
    case quote
    case bulletList

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        case .link: return "Link"
        case .quote: return "Quote"
        case .bulletList: return "Bulleted list"
        }
    }

    var systemImage: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .quote: return "text.quote"
        case .bulletList: return "list.bullet"
        }
    }
}

/// Selection-preserving text edits for the toolbar.
///
/// Each action is a function of `(text, selection)` returning `(text, selection)`: no view state, no
/// first responder, so the boundary cases (empty selection, selection across lines, a selection that
/// already carries the marker) are unit tests. An empty selection inserts the marker pair and puts the
/// caret *between* it, which is what makes "tap bold, type" work.
enum ComposerMarkdownEditing {

    static func apply(_ action: ComposerMarkdownAction,
                      text: String,
                      selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let safe = clamped(selection, in: ns)
        let selected = ns.substring(with: safe)
        switch action {
        case .bold:
            return wrap(text: text, selection: safe, selected: selected, marker: "**")
        case .italic:
            return wrap(text: text, selection: safe, selected: selected, marker: "_")
        case .strikethrough:
            return wrap(text: text, selection: safe, selected: selected, marker: "~~")
        case .code:
            return wrap(text: text, selection: safe, selected: selected, marker: "`")
        case .link:
            return link(text: text, selection: safe, selected: selected)
        case .quote:
            return prefixLines(text: text, selection: safe, prefix: "> ")
        case .bulletList:
            return prefixLines(text: text, selection: safe, prefix: "- ")
        }
    }

    /// The post text a send would produce: leading/trailing blank lines are trimmed, inner text is
    /// untouched (upstream trims only the ends, and a `\n` inside a code fence must survive).
    static func messageForSending(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private static func clamped(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = max(0, min(range.location, ns.length))
        let length = max(0, min(range.length, ns.length - location))
        return NSRange(location: location, length: length)
    }

    private static func wrap(text: String, selection: NSRange, selected: String,
                             marker: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let markerLength = (marker as NSString).length
        let replacement = marker + selected + marker
        let updated = ns.replacingCharacters(in: selection, with: replacement)
        if selected.isEmpty {
            // Caret between the two markers.
            return (updated, NSRange(location: selection.location + markerLength, length: 0))
        }
        return (updated, NSRange(location: selection.location + markerLength,
                                 length: (selected as NSString).length))
    }

    private static func link(text: String, selection: NSRange,
                             selected: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let label = selected.isEmpty ? "text" : selected
        let replacement = "[\(label)](url)"
        let updated = ns.replacingCharacters(in: selection, with: replacement)
        // Select the `url` placeholder: the next thing the user types is the address, which is the
        // half of a link that cannot be inferred from the selection.
        let urlStart = selection.location + (("[\(label)](") as NSString).length
        return (updated, NSRange(location: urlStart, length: 3))
    }

    private static func prefixLines(text: String, selection: NSRange,
                                    prefix: String) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        // The touched lines: from the start of the line containing the selection's start, to the end
        // of the line containing its end (a selection that ends exactly at a line start does not
        // touch the next line).
        let startOfLine = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let endOffset = selection.location + selection.length
        let endOfLine: Int
        if selection.length == 0 {
            endOfLine = NSMaxRange(ns.lineRange(for: NSRange(location: selection.location, length: 0)))
        } else if endOffset > selection.location,
                  endOffset <= ns.length,
                  (endOffset == ns.length || ns.character(at: endOffset) == 0x0A) {
            // Selection ends at a line boundary: the last touched line ends *before* it.
            endOfLine = endOffset
        } else {
            endOfLine = NSMaxRange(ns.lineRange(for: NSRange(location: min(endOffset, ns.length),
                                                            length: 0)))
        }
        let blockRange = NSRange(location: startOfLine, length: max(0, endOfLine - startOfLine))
        let block = ns.substring(with: blockRange)
        let lines = block.components(separatedBy: "\n")
        let prefixed = lines.map { prefix + $0 }.joined(separator: "\n")
        let updated = ns.replacingCharacters(in: blockRange, with: prefixed)
        // Keep the reader's selection where their text is: one prefix was inserted before the
        // selection start, and one more for every line break the selection spans.
        let prefixLength = (prefix as NSString).length
        let selectedRange = NSRange(location: selection.location,
                                    length: selection.length)
        let breaksInside = ns.substring(with: selectedRange).components(separatedBy: "\n").count - 1
        let newLocation = min((updated as NSString).length, selection.location + prefixLength)
        let newLength = min((updated as NSString).length - newLocation,
                            selection.length + max(0, breaksInside) * prefixLength)
        return (updated, NSRange(location: newLocation, length: newLength))
    }
}

// MARK: - Attachments

/// A file the user picked, before it is sent to the server.
struct ComposerUpload: Equatable, Identifiable, Sendable {
    var id: UUID
    var filename: String
    var mimeType: String
    var data: Data

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    var sizeBytes: Int64 { Int64(data.count) }

    /// What the server will call this file: the composer shows the name before the upload answers, and
    /// the sanitising rule has to be the same one the multipart writer uses.
    var safeFilename: String { MMMultipart.sanitizedFilename(filename) }
}

/// One attachment as the composer's tray draws it.
struct ComposerAttachment: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        /// Picked, not started (or waiting for a retry).
        case queued
        /// `progress` is 0…1 from the transport, not a guess.
        case uploading(progress: Double)
        case uploaded(fileID: String)
        case failed(String)
    }

    var id: UUID
    var filename: String
    var mimeType: String
    var sizeBytes: Int64
    var state: State

    var fileID: String? {
        if case .uploaded(let fileID) = state { return fileID }
        return nil
    }

    var isUploaded: Bool { fileID != nil }
    var isUploading: Bool {
        if case .uploading = state { return true }
        return false
    }

    /// "1.2 MB" — the same base-1024 formatting the post rows use, so a file does not change size
    /// between the tray and the row it becomes.
    var sizeLabel: String { PostAttachment.sizeLabel(forBytes: sizeBytes) }
}

// MARK: - Drafts

/// A file that was uploaded but not sent, as the draft keeps it so a relaunch can still send it.
struct ComposerStoredFile: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var mimeType: String
    var size: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case mimeType = "mime_type"
    }
}

/// What the composer remembers about one (channel, thread root) between appearances.
///
/// `rootID` is part of the identity because upstream keeps a separate draft per thread; a reply you
/// started in a thread must not appear in the channel's main composer.
struct ComposerDraft: Equatable, Sendable {
    var channelID: String
    var rootID: String
    var message: String
    var files: [ComposerStoredFile]
    var updateAt: Int64

    init(channelID: String,
         rootID: String = "",
         message: String = "",
         files: [ComposerStoredFile] = [],
         updateAt: Int64 = 0) {
        self.channelID = channelID
        self.rootID = rootID
        self.message = message
        self.files = files
        self.updateAt = updateAt
    }

    /// Whether this draft is worth a row on disk: an empty message with no files is the same as no
    /// draft, and keeping it would make "clear the draft" a no-op on the next launch.
    var isEmpty: Bool { message.isEmpty && files.isEmpty }

    static func now(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}

// MARK: - Request bodies

/// `POST /posts`. Field names are the documented ones (https://api.mattermost.com/#tag/posts).
struct ComposerPostBody: Encodable, Equatable, Sendable {
    var channelId: String
    var message: String
    var rootId: String?
    var fileIds: [String]?
    var pendingPostId: String?

    enum CodingKeys: String, CodingKey {
        case message
        case channelId = "channel_id"
        case rootId = "root_id"
        case fileIds = "file_ids"
        case pendingPostId = "pending_post_id"
    }
}

/// `PUT /posts/{id}`. The server requires the post's own id in the body (it is how it refuses a patch
/// that would move a post between channels), so the body carries it rather than only the path.
struct ComposerPostPatch: Encodable, Equatable, Sendable {
    var id: String
    var message: String
    var fileIds: [String]?

    enum CodingKeys: String, CodingKey {
        case id, message
        case fileIds = "file_ids"
    }
}

/// `POST /files` → `{"file_infos":[…]}`.
struct MMFileUploadResponse: Codable, Equatable, Sendable {
    var fileInfos: [MMFileInfo]

    enum CodingKeys: String, CodingKey {
        case fileInfos = "file_infos"
    }
}

// MARK: - Membership

/// The client-side half of "a mention only offers people who can actually read the channel".
///
/// The server-side half is the documented query parameter: `GET /users/autocomplete?in_channel_id=`
/// only returns members. That is trusted only when the client can also *check* it: the member list is
/// paged in and, when the whole list was read, any candidate that is not in it is dropped. When the
/// list is truncated (a very large channel, or a failed page) the filter stands down rather than
/// hiding a real member — an autocomplete that omits a colleague is worse than one that offers a
/// stale name, because the mention still works either way.
enum ComposerMembership {
    struct MemberList: Equatable, Sendable {
        var ids: Set<String>
        /// True only when every page was read (the last one was short).
        var isComplete: Bool

        static let unknown = MemberList(ids: [], isComplete: false)
    }

    static func filter(_ candidates: [ComposerSuggestion],
                       members: MemberList) -> [ComposerSuggestion] {
        guard members.isComplete else { return candidates }
        return candidates.filter { suggestion in
            switch suggestion.kind {
            case .specialMention:
                return true     // `@channel` is not a person
            case .user:
                // A suggestion without a server id cannot be checked, so it is kept: an
                // autocomplete that omits a real colleague is worse than one that offers a stale
                // name, because the mention still works either way.
                guard let userID = suggestion.userID, !userID.isEmpty else { return true }
                return members.ids.contains(userID.lowercased())
            case .channel, .emoji:
                return true
            }
        }
    }
}

// MARK: - Row permissions

/// Who may edit or delete a row, as one pure rule (T35).
///
/// The composer's row menu asks this, and nothing else decides it: the server enforces the same
/// thing, but an affordance that always fails is not an affordance. Two "unknown" cases are
/// deliberately *not* permissive: an empty `userId` on the post and a `nil` author id (a session
/// whose user has not resolved yet) mean "cannot tell", and "cannot tell" must not offer a
/// destructive action on someone else's message.
///
/// Found by the T35 live suite: the options sheet is built from this rule, and the first version
/// compared a username against a set of user ids in one place while comparing ids in another.
enum ComposerRowPermissions {
    static func isMine(postUserID: String, authorID: String?) -> Bool {
        guard let authorID, !authorID.isEmpty else { return false }
        let postUserID = postUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !postUserID.isEmpty else { return false }
        return postUserID == authorID
    }

    /// Whether the row offers a menu at all, and which entries it holds. `nil` = no menu: the row
    /// is a system line, a tombstone or an optimistic row the server has not answered yet.
    static func menu(postUserID: String,
                     authorID: String?,
                     isSystem: Bool,
                     isDeleted: Bool,
                     isPending: Bool,
                     canReply: Bool = true) -> (reply: Bool, edit: Bool, delete: Bool)? {
        guard !isSystem, !isDeleted, !isPending else { return nil }
        let mine = isMine(postUserID: postUserID, authorID: authorID)
        let menu = (reply: canReply, edit: mine, delete: mine)
        return menu.reply || menu.edit || menu.delete ? menu : nil
    }
}

// MARK: - Sorting

/// Ordering for the suggestion list, and the ranking that makes typing two letters useful.
///
/// Prefix matches come first (in the server's own order), then substring matches. Ties keep the
/// server's order, which is what makes the first row stable while the user types — a list that
/// re-sorts itself on every keystroke moves the row under the finger.
enum ComposerSuggestionRanking {

    static func ranked(_ suggestions: [ComposerSuggestion],
                       term: String,
                       limit: Int = 12) -> [ComposerSuggestion] {
        guard limit > 0 else { return [] }
        let needle = term.lowercased()
        guard !needle.isEmpty else { return Array(suggestions.prefix(limit)) }
        var prefix: [ComposerSuggestion] = []
        var contains: [ComposerSuggestion] = []
        for suggestion in suggestions {
            let value = suggestion.value.lowercased()
            if value.hasPrefix(needle) {
                prefix.append(suggestion)
            } else if value.contains(needle) {
                contains.append(suggestion)
            } else if suggestion.label.lowercased().contains(needle) {
                contains.append(suggestion)
            }
        }
        return Array((prefix + contains).prefix(limit))
    }
}

// MARK: - The Return key

/// What the Return key means in the composer input.
///
/// Enter sends; Shift+Enter starts a new line. It is a pure rule rather than an `if` buried in the
/// text view, because the bridge can only ever report "a newline arrived, and shift was (or was not)
/// down" — the decision itself is what has to be pinned by a test.
enum ComposerReturnPolicy {

    enum Action: Equatable {
        /// Send the message as it stands.
        case send
        /// Let the newline through: a multi-line message.
        case newline
        /// Not the Return key — leave the text system alone.
        case passThrough
    }

    /// - Parameters:
    ///   - isReturnKey: the key was Return/Enter (the on-screen keyboard's Return counts as one).
    ///   - shiftPressed: a hardware shift is down. The on-screen keyboard reports no modifiers, so a
    ///     tap on its Return sends — which is Mattermost's own default on mobile.
    static func action(isReturnKey: Bool, shiftPressed: Bool) -> Action {
        guard isReturnKey else { return .passThrough }
        return shiftPressed ? .newline : .send
    }
}
