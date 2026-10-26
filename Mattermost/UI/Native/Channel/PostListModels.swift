// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_list/post_list.tsx (the list's items: date separators, the new-messages
//        line, posts, combined system messages), app/components/post_list/date_separator/
//        date_separator.tsx (today/yesterday/weekday/date titles), app/components/post_list/
//        new_message_line/ (where the unread divider goes), app/components/post/index.tsx and
//        post/header/ (avatar + author + time, and the "grouped" variant that omits the header),
//        app/components/post_body/post_body.tsx (edited marker, deleted tombstone, system messages),
//        app/components/post_body/system_message.tsx, app/components/reactions/ (the summary row),
//        app/components/files/ (attachment rows), app/utils/post_list/index.ts (ordering and the
//        `isSameUser`/collapse window), app/utils/datetime.ts.
// Licence: Apache-2.0 — ported as behaviour with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. Pure derivation: no I/O, no main actor, no SwiftUI, so every rule below is
// asserted by a unit test (docs/component-map.md §4 "logic-first").
//
// Deliberate deltas, recorded in docs/t34-build-note.md §10:
//  - avatars are drawn from initials + a stable hue instead of a fetched profile image (profile
//    images are S24/T41's card; the row must not block on a second request per author);
//  - a post is folded ("Show more") by *block count, and by line/character caps inside a block*,
//    where upstream measures rendered height. Height is a layout answer; this card owns a
//    deterministic answer the layout can use, and the in-block caps are what keep a post that is one
//    5,000-line fence or one 40,000-character paragraph from taking over the screen.

import Foundation

// MARK: - Author

/// Who wrote a post, as the row draws them.
struct PostAuthor: Equatable, Sendable {
    var id: String
    var username: String
    /// The name a person reads: nickname, else "First Last", else the username.
    var displayName: String
    var initials: String
    /// 0…1 hue for the initials avatar — stable for a user id, so a person keeps one colour.
    var avatarHue: Double

    init(id: String, username: String, displayName: String) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.initials = Self.initials(displayName: displayName, username: username)
        self.avatarHue = Self.hue(for: id)
    }

    static func initials(displayName: String, username: String) -> String {
        let words = displayName.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        let single = words.first.map(String.init) ?? username
        return String(single.prefix(2)).uppercased()
    }

    /// A stable, even spread of hues over the user id. `hashValue` is deliberately not used: Swift
    /// randomises it per process, which would recolour every avatar on relaunch.
    static func hue(for id: String) -> Double {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Double(hash % 360) / 360.0
    }
}

// MARK: - Reactions

/// One emoji's worth of reactions on a post: `:tada: ×2` and whether I am one of them.
struct PostReactionSummary: Equatable, Identifiable, Sendable {
    var emojiName: String
    var count: Int
    var includesMe: Bool
    /// User ids in server order — the reaction bar's tooltip/VoiceOver detail (S16 draws the list).
    var userIds: [String]

    var id: String { emojiName }
}

// MARK: - Attachments

/// One file attached to a post.
struct PostAttachment: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case image
        case file
    }

    var id: String
    var name: String
    var mimeType: String
    var sizeBytes: Int64
    var kind: Kind
    var isBlocked: Bool
    /// The server can produce a thumbnail for this file (only for images it recognises).
    var hasThumbnail: Bool

    /// "812 B", "1.2 KB", "3.4 MB" — base 1024, one decimal from KB up (upstream's `sizeDisplay`).
    var sizeLabel: String { Self.sizeLabel(forBytes: sizeBytes) }

    static func sizeLabel(forBytes sizeBytes: Int64) -> String {
        guard sizeBytes > 0 else { return "" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(sizeBytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        return String(format: "%.1f %@", value, units[unit])
    }

    static func kind(forMimeType mimeType: String) -> Kind {
        mimeType.lowercased().hasPrefix("image/") ? .image : .file
    }
}

// MARK: - A post row

/// One post as the list draws it: everything is precomputed so the row is a value, not a request.
struct PostRowModel: Equatable, Identifiable, Sendable {
    var post: MMPost
    var author: PostAuthor
    /// True when the row omits the avatar/author/time header because it continues the previous post
    /// by the same author inside the collapse window.
    var isGrouped: Bool
    /// `post.type != ""`: a system message ("x added y to the channel"), drawn as one line, never markdown.
    var isSystem: Bool
    var isDeleted: Bool
    var isEdited: Bool
    var isPinned: Bool
    /// The parsed body. Empty for a system message (its text is `post.message`, plain) and for a
    /// deleted post (its body is the tombstone).
    var blocks: [MarkdownBlock]
    var reactions: [PostReactionSummary]
    var attachments: [PostAttachment]
    var replyCount: Int
    /// T35: an optimistic row the composer inserted, whose `id` is a local `pending:<uuid>`. The row
    /// draws a muted "Sending…" status and is not yet a fact about the conversation.
    var isPending: Bool = false
    /// How this post is shortened until the reader asks for more; `nil` = draw it in full.
    var fold: PostFold?

    var id: String { post.id }

    /// The plain text of the post, for accessibility and for tests. System and deleted posts have
    /// their own wording (which is what a screen reader should say).
    var accessibleText: String {
        if isDeleted { return "This message was deleted." }
        if isSystem { return post.message }
        return blocks.map(\.plainText).joined(separator: "\n")
    }

    /// The body while folded: the blocks the fold kept, with the last one already shortened if it was
    /// one huge block (code fence, paragraph, table). `fold == nil` means "nothing is hidden".
    var blocksToShow: [MarkdownBlock] {
        fold?.visibleBlocks ?? blocks
    }

    /// What is hidden while folded ("… 4,980 more lines"). Empty when nothing is folded.
    var foldSummary: String { fold?.hiddenSummary ?? "" }

    func showsAllBlocks(expanded: Bool) -> Bool { expanded || fold == nil }
}

/// A folded post's visible prefix, plus the sentence that says what is not visible.
///
/// The summary exists so folding never silently drops content: the reader sees "… 4,980 more lines"
/// next to the affordance, instead of an unlabelled "Show more" that hides an unknown amount.
struct PostFold: Equatable, Sendable {
    var visibleBlocks: [MarkdownBlock]
    var hiddenSummary: String
}

// MARK: - List items

/// A day boundary in the list.
struct PostDateSeparator: Equatable, Identifiable, Sendable {
    /// `yyyy-MM-dd` in the *user's* calendar, so it is stable across a re-derive in one day.
    var dayKey: String
    /// "Today", "Yesterday", "Tuesday" (this week) or a full date.
    var title: String

    var id: String { "date-\(dayKey)" }
}

/// One element of the rendered list, in **display order (oldest first, top to bottom)**.
enum PostListItem: Equatable, Identifiable, Sendable {
    case dateSeparator(PostDateSeparator)
    case newMessages
    case post(PostRowModel)

    var id: String {
        switch self {
        case .dateSeparator(let separator): return separator.id
        case .newMessages: return "new-messages"
        case .post(let row): return "post-\(row.id)"
        }
    }

    /// The post id, when this item is a post (the view's scroll anchor is a post, never a separator).
    var postID: String? {
        if case .post(let row) = self { return row.id }
        return nil
    }
}

// MARK: - Derivation

/// The pure rules behind the list. Everything here is a function of its arguments — no clock, no
/// calendar singleton, no network — so the tests can pin a day boundary or a 5-minute edge exactly.
enum PostListDerivation {

    /// Posts by the same author closer together than this are grouped (upstream's
    /// `POST_COLLAPSE_TIMEOUT` is 5 minutes; `app/utils/post_list/index.ts`).
    static let groupingWindow: Int64 = 5 * 60 * 1000

    /// A post longer than this many blocks (or characters) is folded behind "Show more".
    static let foldBlockThreshold = 12
    static let foldCharacterThreshold = 2500
    /// How many blocks a folded post shows before the affordance.
    static let foldedBlockCount = 6

    /// Build the display list from a channel page.
    ///
    /// - Parameters:
    ///   - posts: the loaded window, in **any** order (the server's newest-first is what the view
    ///     model holds; this sorts ascending by `create_at`, id as the tiebreaker so two posts with
    ///     the same millisecond never swap between renders).
    ///   - users: author lookup by id (the batch `/users/ids` answer).
    ///   - myUserID: whose posts do not get a "new messages" divider before them.
    ///   - lastViewedAt: `channel_member.last_viewed_at`; `nil` = unknown, so no divider is invented.
    static func items(posts: [MMPost],
                      users: [String: MMUser],
                      myUserID: String?,
                      lastViewedAt: Int64?,
                      expandedPostIDs: Set<String> = [],
                      pendingPostIDs: Set<String> = [],
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      locale: Locale = .current) -> [PostListItem] {
        let ordered = posts
            .filter { !$0.id.isEmpty }
            .sorted { lhs, rhs in
                if lhs.createAt != rhs.createAt { return lhs.createAt < rhs.createAt }
                return lhs.id < rhs.id
            }

        var items: [PostListItem] = []
        var lastDayKey: String?
        var previous: MMPost?
        var insertedNewMessages = false

        for post in ordered {
            let dayKey = Self.dayKey(for: post.createAt, calendar: calendar)
            let isNewDay = dayKey != lastDayKey
            if isNewDay {
                items.append(.dateSeparator(PostDateSeparator(
                    dayKey: dayKey,
                    title: dayTitle(for: post.createAt, now: now, calendar: calendar, locale: locale))))
                lastDayKey = dayKey
            }

            // The divider goes before the first post the user has not seen, *after* the day separator,
            // and never before one of their own posts (upstream's new-message line skips them).
            if !insertedNewMessages, let lastViewedAt, post.createAt > lastViewedAt,
               post.userId != myUserID, post.deleteAt == 0, post.type.isEmpty {
                items.append(.newMessages)
                insertedNewMessages = true
            }

            let isSystem = !post.type.isEmpty
            let grouped = !isNewDay
                && previous != nil
                && previous?.userId == post.userId
                && !isSystem
                && previous?.type.isEmpty == true
                && (post.createAt - (previous?.createAt ?? 0)) < groupingWindow

            items.append(.post(row(post: post,
                                   users: users,
                                   myUserID: myUserID,
                                   grouped: grouped,
                                   expanded: expandedPostIDs.contains(post.id),
                                   pending: pendingPostIDs.contains(post.id))))
            previous = post
        }
        return items
    }

    /// One row, with every derived field the view needs.
    static func row(post: MMPost,
                    users: [String: MMUser],
                    myUserID: String?,
                    grouped: Bool,
                    expanded: Bool = false,
                    pending: Bool = false) -> PostRowModel {
        let isSystem = !post.type.isEmpty
        let isDeleted = post.deleteAt > 0
        let blocks = (isSystem || isDeleted) ? [] : MarkdownParser().parse(post.message)
        let fold = fold(for: post, blocks: blocks, expanded: expanded)
        return PostRowModel(post: post,
                            author: author(for: post, users: users),
                            isGrouped: grouped && !isSystem && !isDeleted,
                            isSystem: isSystem,
                            isDeleted: isDeleted,
                            isEdited: post.editAt > 0 && !isDeleted,
                            isPinned: post.isPinned,
                            blocks: blocks,
                            reactions: reactions(for: post, myUserID: myUserID),
                            attachments: attachments(for: post),
                            replyCount: post.replyCount,
                            isPending: pending,
                            fold: fold)
    }

    /// Decide what a folded post shows.
    ///
    /// Two rules, in this order:
    ///  1. **too many blocks** — keep the first `foldedBlockCount` (never all of them, so the
    ///     affordance always does something);
    ///  2. **one block that is too tall** — shorten that block from the inside (`MarkdownFold`), so a
    ///     single 5,000-line fence or a 40,000-character paragraph is bounded too. This is the case
    ///     the block-count-only rule got wrong: it returned "1 block" and drew all 5,000 lines.
    ///
    /// A post that trips the length threshold but whose content genuinely fits (2 medium blocks) is
    /// not folded at all — a "Show more" that shows nothing new is worse than no affordance.
    static func fold(for post: MMPost, blocks: [MarkdownBlock], expanded: Bool) -> PostFold? {
        guard !expanded, !blocks.isEmpty else { return nil }
        let overBlocks = blocks.count > foldBlockThreshold
        let overCharacters = post.message.count > foldCharacterThreshold
        guard overBlocks || overCharacters else { return nil }

        let keepCount = overBlocks ? min(foldedBlockCount, max(1, blocks.count - 1)) : blocks.count
        var visible = Array(blocks.prefix(keepCount))

        var notes: [String] = []
        var shortened = false
        // The last kept block is the one at the fold edge; if it is itself huge it must be clipped.
        for index in visible.indices.reversed() {
            guard let clip = MarkdownFold.shorten(visible[index]) else { continue }
            visible[index] = clip.block
            notes.append(clip.note)
            shortened = true
            break
        }

        let hiddenBlocks = blocks.count - visible.count
        if hiddenBlocks > 0 {
            notes.insert("… \(MarkdownFold.number(hiddenBlocks)) more "
                         + (hiddenBlocks == 1 ? "block" : "blocks"), at: 0)
        }
        // Length tripped but nothing was actually hidden: draw the post whole.
        guard hiddenBlocks > 0 || shortened else { return nil }
        return PostFold(visibleBlocks: visible, hiddenSummary: notes.joined(separator: " · "))
    }

    static func author(for post: MMPost, users: [String: MMUser]) -> PostAuthor {
        if let user = users[post.userId] {
            return PostAuthor(id: user.id,
                              username: user.username,
                              displayName: displayName(for: user))
        }
        // No profile yet (the batch request is still in flight, or the author was deleted): the post
        // itself often carries the username in `props` for system messages, and the id is a fact.
        let username = post.props?["username"]?.stringValue
            ?? post.props?["addedUsername"]?.stringValue
            ?? ""
        let label = username.isEmpty ? "Unknown user" : username
        return PostAuthor(id: post.userId, username: username, displayName: label)
    }

    static func displayName(for user: MMUser) -> String {
        if !user.nickname.isEmpty { return user.nickname }
        let full = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return user.username
    }

    // MARK: Reactions

    /// Reactions from `post.metadata.reactions` (the channel-posts endpoint includes them; a server
    /// that omits the field simply has no reactions on that page — verified 2026-10-25, see the build
    /// note §4).
    static func reactions(for post: MMPost, myUserID: String?) -> [PostReactionSummary] {
        guard let raw = post.metadata?["reactions"]?.arrayValue, !raw.isEmpty else { return [] }
        var order: [String] = []
        var grouped: [String: PostReactionSummary] = [:]
        for value in raw {
            guard let reaction = try? MMRawJSON(value).decode(MMReaction.self),
                  !reaction.emojiName.isEmpty else { continue }
            if grouped[reaction.emojiName] == nil {
                order.append(reaction.emojiName)
                grouped[reaction.emojiName] = PostReactionSummary(emojiName: reaction.emojiName,
                                                                  count: 0,
                                                                  includesMe: false,
                                                                  userIds: [])
            }
            grouped[reaction.emojiName]?.count += 1
            grouped[reaction.emojiName]?.userIds.append(reaction.userId)
            if reaction.userId == myUserID {
                grouped[reaction.emojiName]?.includesMe = true
            }
        }
        // Most-reacted first (the reaction bar's rule), then by name so the order is deterministic.
        return order.compactMap { grouped[$0] }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.emojiName < rhs.emojiName
            }
    }

    // MARK: Attachments

    /// Files from `post.metadata.files`, falling back to the `file_ids` the post carries (so a page
    /// without metadata still shows that *something* is attached instead of silently dropping it).
    static func attachments(for post: MMPost) -> [PostAttachment] {
        if let raw = post.metadata?["files"]?.arrayValue, !raw.isEmpty {
            return raw.compactMap { value in
                guard let file = try? MMRawJSON(value).decode(MMFileInfo.self), !file.id.isEmpty else {
                    return nil
                }
                return PostAttachment(id: file.id,
                                      name: file.name.isEmpty ? file.id : file.name,
                                      mimeType: file.mimeType,
                                      sizeBytes: file.size,
                                      kind: PostAttachment.kind(forMimeType: file.mimeType),
                                      isBlocked: file.isBlocked,
                                      hasThumbnail: PostAttachment.kind(forMimeType: file.mimeType) == .image
                                          && !file.isBlocked)
            }
        }
        return post.fileIds.map { id in
            PostAttachment(id: id, name: "Attachment", mimeType: "", sizeBytes: 0,
                           kind: .file, isBlocked: false, hasThumbnail: false)
        }
    }

    // MARK: Dates

    static func dayKey(for milliseconds: Int64, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// "Today", "Yesterday", the weekday within the last week, otherwise a full date.
    ///
    /// The weekday/full-date titles are produced by `Date.FormatStyle`, so they follow the user's
    /// locale instead of a hand-rolled English table (the failure mode of a hard-coded one is a
    /// German phone reading "Tuesday").
    static func dayTitle(for milliseconds: Int64, now: Date, calendar: Calendar,
                         locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 99
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale)
            .weekday(.wide)
            .month(.wide)
            .day()
            .year()
        if days < 7 {
            style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale).weekday(.wide)
        }
        return date.formatted(style)
    }

    /// "3:45 PM" (locale-dependent) for a post's own timestamp.
    static func timeTitle(for milliseconds: Int64, calendar: Calendar, locale: Locale,
                          timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: timeZone)
        style = style.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(style)
    }
}
