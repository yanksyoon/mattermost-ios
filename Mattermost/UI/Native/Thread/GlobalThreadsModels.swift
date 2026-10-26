// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/global_threads/threads_list/thread.tsx (a row: root author avatar, channel name,
//        the root message's first lines, the reply count, the unread dot), and
//        app/screens/global_threads/global_threads.tsx (the All / Unreads tabs).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied.
//
// One row per followed thread, derived from the server's thread object with no I/O, so the list's
// copy, ordering and badge rules are pinnable by unit tests (the view model only moves the data).

import Foundation

/// One followed thread as the global list draws it.
struct GlobalThreadRow: Equatable, Identifiable, Sendable {
    var threadID: String
    var channelID: String
    var author: PostAuthor
    /// The root message as one line: markdown stripped, whitespace collapsed, clipped to a preview.
    var preview: String
    var replyCount: Int
    var unread: ThreadUnread
    var isUrgent: Bool
    /// The instant the row's time label is about (its last reply, or the root's creation).
    var activityAt: Int64
    /// The time label the row draws ("2:15 PM", "Yesterday").
    var timeLabel: String
    /// Whether the current user wrote the root (the row says "You" instead of repeating the name).
    var isMine: Bool

    var id: String { threadID }
}

enum GlobalThreadsDerivation {

    /// How much of the root message a row shows. Upstream clips the rendered first lines; this client
    /// clips the **plain text** at a character count so the row's height cannot depend on how much
    /// markdown a message happens to contain.
    static let previewLength = 140

    /// The plain text of a post (markdown stripped) collapsed to one line.
    static func plainText(_ message: String) -> String {
        let blocks = MarkdownParser().parse(message)
        let text = blocks.map(\.plainText).joined(separator: " ")
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The preview a row draws: one line, at most `previewLength` characters plus an ellipsis.
    static func preview(_ message: String, limit: Int = previewLength) -> String {
        let text = plainText(message)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Rows for a page of threads, in the list's own order (the caller has already sorted them).
    static func rows(threads: [MMThread],
                     users: [String: MMUser],
                     myUserID: String?,
                     now: Date = Date(),
                     calendar: Calendar = .current,
                     locale: Locale = .current,
                     timeZone: TimeZone = .current) -> [GlobalThreadRow] {
        threads.map { thread in
            let activityAt = ThreadDerivation.activityAt(thread)
            let root = thread.post
            let author = PostListDerivation.author(for: root, users: users)
            let preview = preview(root.message)
            return GlobalThreadRow(
                threadID: thread.id,
                channelID: root.channelId,
                author: author,
                // A deleted or empty root still needs a line: the tombstone wording is the honest
                // one, and a row with no text would look like a rendering bug.
                preview: preview.isEmpty ? (root.deleteAt > 0 ? "This message was deleted." : "(no text)") : preview,
                replyCount: thread.displayedReplyCount,
                unread: thread.unread,
                isUrgent: thread.isUrgent,
                activityAt: activityAt,
                timeLabel: PostListDerivation.timeTitle(for: activityAt,
                                                        calendar: calendar,
                                                        locale: locale,
                                                        timeZone: timeZone),
                isMine: !root.userId.isEmpty && root.userId == myUserID)
        }
    }

    /// The users a page of rows needs profiles for (root authors and participants).
    static func profileIDs(in threads: [MMThread]) -> [String] {
        var ids = Set<String>()
        for thread in threads {
            if !thread.post.userId.isEmpty { ids.insert(thread.post.userId) }
            for participant in thread.participants where !participant.id.isEmpty { ids.insert(participant.id) }
        }
        return Array(ids)
    }

    /// What the tab bar says above the list ("3 unread" / "All your threads").
    static func tabSubtitle(totals: ThreadTotals, tab: GlobalThreadsTab) -> String {
        switch tab {
        case .unreads:
            if totals.unreadThreads == 0 { return "No unread threads" }
            return totals.unreadThreads == 1 ? "1 unread thread" : "\(totals.unreadThreads) unread threads"
        case .all:
            if totals.total == 0 { return "No threads yet" }
            return totals.total == 1 ? "1 thread" : "\(totals.total) threads"
        }
    }
}

/// The two tabs upstream's `global_threads` screen offers.
enum GlobalThreadsTab: String, CaseIterable, Identifiable, Sendable {
    case all
    case unreads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All your threads"
        case .unreads: return "Unreads"
        }
    }
}
