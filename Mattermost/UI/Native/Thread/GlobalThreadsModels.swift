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

    /// The counters the header draws.
    ///
    /// The server's totals are the source, but a counter line and a row set must never contradict
    /// each other: an empty `total` drawn over a page that has rows is a defect the reader sees as
    /// "No threads yet" above a full list (T36-AV F3, reproduced). So a zero `total` is replaced by
    /// the number of threads actually drawn, and the same for the unread counter — the drawn rows are
    /// the lower bound of what exists, so this can only ever *under*-state, never invent a thread.
    static func displayedTotals(_ totals: ThreadTotals, drawn threads: [MMThread]) -> ThreadTotals {
        guard !threads.isEmpty else { return totals }
        var result = totals
        if result.total < threads.count { result.total = threads.count }
        let unreadDrawn = threads.filter { $0.unread.isUnread }.count
        if result.unreadThreads < unreadDrawn { result.unreadThreads = unreadDrawn }
        if result.unreadMentions < threads.filter({ $0.unreadMentions > 0 }).count {
            result.unreadMentions = threads.filter { $0.unreadMentions > 0 }.count
        }
        if result.unreadUrgentMentions < threads.filter({ $0.isUrgent }).count {
            result.unreadUrgentMentions = threads.filter { $0.isUrgent }.count
        }
        return result
    }

    /// The rail's view of the counters.
    ///
    /// Deliberately the **same** rule the pane's header uses (`displayedTotals`): the server's totals,
    /// bounded below by the rows already drawn. A rail badge and a pane header that could disagree
    /// would be two numbers for one question, and the reader has no way to tell which is right —
    /// so they are derived from one function and pinned together by test.
    static func railEntry(totals: ThreadTotals, drawn threads: [MMThread]) -> ThreadsRailEntry {
        let displayed = displayedTotals(totals, drawn: threads)
        return ThreadsRailEntry(unreadThreads: displayed.unreadThreads,
                                mentions: displayed.unreadMentions)
    }
}

/// What the rail's Threads entry (the sidebar row, and the phone's Threads tab) has to say while the
/// pane is **closed**.
///
/// This is the value the reported complaint was missing: "no place in the left panel to see unread
/// threads". A reader must be able to tell, from the channel list alone, that threads are waiting and
/// how many, without opening the pane to find out — so the entry carries both facts the pane's own
/// header carries: whether anything is unread (upstream's `unreads`, which bolds the Threads button in
/// `app/components/threads_button/threads_button.tsx`) and how many threads are unread (the badge).
///
/// The number is the **unread thread** count, not upstream mobile's thread-mention sum: this client's
/// pane counts unread threads (`GlobalThreadsDerivation.tabSubtitle`, "12 unread threads"), and a rail
/// badge that answered a different question than the header one tap away would be the kind of
/// disagreement T36-AV F3 was about. Mentions are not lost — they are named in
/// ``accessibilityValue``, so VoiceOver hears "12 unread threads, 11 mentions".
struct ThreadsRailEntry: Equatable, Sendable {
    var unreadThreads: Int = 0
    var mentions: Int = 0

    static let none = ThreadsRailEntry()

    /// Whether the row draws its unread emphasis. Mentions alone can leave a thread counted as read
    /// (a channel read clears replies but not a thread's mention counter — measured in T42), so the
    /// emphasis is "anything waiting", not "unreadThreads > 0".
    var isUnread: Bool { unreadThreads > 0 || mentions > 0 }

    /// The badge's text. Zero draws **nothing**: an always-visible "0" reads as a load that failed,
    /// which is exactly how the missing unread state looked when this card was reported.
    var badgeText: String? { unreadThreads > 0 ? "\(unreadThreads)" : nil }

    /// What a VoiceOver reader hears for the row, in the order the numbers matter.
    var accessibilityValue: String {
        var parts: [String] = []
        if unreadThreads > 0 {
            parts.append(unreadThreads == 1 ? "1 unread thread" : "\(unreadThreads) unread threads")
        }
        if mentions > 0 {
            parts.append(mentions == 1 ? "1 mention" : "\(mentions) mentions")
        }
        return parts.isEmpty ? "No unread threads" : parts.joined(separator: ", ")
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
