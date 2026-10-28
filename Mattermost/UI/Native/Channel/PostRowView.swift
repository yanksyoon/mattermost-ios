// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post/index.tsx (a row = avatar + header + body + attachments + reactions, the
//        `isPostAddChannelMember`/system branch, and the "no header" `isGrouped` variant),
//        post/header/post_header.tsx (author, time, edited marker, pinned marker),
//        post/avatar (44 pt initials avatar), post_body/post_body.tsx (fold/expand, deleted tombstone),
//        post_body/system_message.tsx (one line, info glyph), reactions/reaction_bar.tsx (the summary
//        capsules), files/file_upload_item/* and files/image_file (thumbnail vs file row),
//        post_list/date_separator/date_separator.tsx, post_list/new_message_line/new_message_line.tsx.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. SwiftUI decomposition is this repo's own (component-map.md §1).
//
// Identifiers an XCUITest can rely on (also listed in docs/t34-build-note.md §7):
//   post.<id>                  the row (a container)
//   post.<id>.body             the body text of a message post
//   post.<id>.author           the author name (absent on a grouped row — that is the point)
//   post.<id>.edited           "(edited)"
//   post.<id>.deleted          the tombstone
//   post.<id>.system           a system message line
//   post.<id>.showMore         the fold affordance
//   post.<id>.foldSummary      what the fold is hiding ("… 4,980 more lines")
//   post.<id>.reaction.<emoji> one reaction summary
//   post.<id>.attachment.<fileID> one attachment row
//   channelDateSeparator.<dayKey>  a day boundary
//   channelNewMessages         the unread divider

import SwiftUI
import UIKit

// MARK: - Date separator

struct PostDateSeparatorView: View {
    let separator: PostDateSeparator

    var body: some View {
        HStack(spacing: 8) {
            line
            Text(separator.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground), in: Capsule())
            line
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Messages from \(separator.title)")
        .accessibilityIdentifier("channelDateSeparator.\(separator.dayKey)")
    }

    private var line: some View {
        Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
    }
}

// MARK: - New messages

struct NewMessagesDividerView: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(height: 1)
            Text("New messages")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Rectangle().fill(Color.accentColor).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channelNewMessages")
    }
}

/// The separator a list draws where messages are missing (T39).
///
/// Deliberately not a "New messages" style accent line: this is not a milestone the server told us
/// about, it is an absence. Dashed rules and secondary text so it reads as "there is nothing here",
/// with its own identifier so a test can assert the jump did not draw a continuous list.
struct PostListGapView: View {
    let gap: PostListGap

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                dash
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(gap.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                dash
            }
            Text(gap.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channelListGap")
    }

    private var dash: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(height: 1)
    }
}

// MARK: - Avatar

struct PostAvatarView: View {
    let author: PostAuthor
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hue: author.avatarHue, saturation: 0.45, brightness: 0.82))
            if author.initials.isEmpty {
                // A participant the server sent as an id-only stub: an avatar is honest, an invented
                // name is not (T36).
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(author.initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // The server's own picture, once it lands. Drawn last so it covers the initials; draws
            // nothing at all while loading, for an account without a picture, or in a preview/host
            // that has no session — the circle and the initials stay exactly as they were.
            AvatarPicture(userID: author.id, size: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One face in a root row's participant stack (T36): the same avatar, small, with a background ring
/// so overlapping circles stay distinguishable.
struct PostParticipantAvatarView: View {
    let author: PostAuthor
    var size: CGFloat = 20

    var body: some View {
        PostAvatarView(author: author, size: size)
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
    }
}

// MARK: - One post

/// What a reader can do with a row (T35). The list owns the model, so the actions are closures the
/// pane passes in; the row itself never decides who may edit what.
struct PostRowActions {
    var canReply: Bool
    var canEdit: Bool
    var canDelete: Bool
    var onReply: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    /// Ask the host to present this row's options. The *list* owns the sheet: one sheet for the
    /// whole window, not one per row.
    var onShowOptions: () -> Void
    /// T37: ask the host to present the emoji picker for this row. The picker is likewise one sheet
    /// for the window; a row only says *which* post it was opened for.
    var canReact: Bool = false
    var onReact: () -> Void = {}
    /// T48: whether this host draws the post-options surface at all.
    ///
    /// The options that do not touch the composer — copy text, copy link, save, pin, mark unread,
    /// follow thread — exist whether or not the write surface is native, so the overflow button must
    /// not disappear with the composer. The sheet derives the exact rows from
    /// `PostOptionsCapabilities`; this flag only says "there is a sheet to open".
    var showsOptions: Bool = false

    /// Whether there is anything to offer at all — an empty sheet is a worse affordance than none.
    var hasAnyAction: Bool { canReply || canEdit || canDelete || canReact || showsOptions }
}

/// What a reader can do with a row's reaction bar (T37). Nil is the read-only rendering the older
/// hosts and the previews use: pills are drawn, nothing can be pressed.
struct PostRowReactionActions {
    /// Toggle one pill (the emoji name as the *row* spells it — the coordinator canonicalises).
    var onToggle: (String) -> Void
    /// Long press / VoiceOver action on a pill: who reacted.
    var onShowReactors: (String) -> Void
    /// The `+` chip that opens the picker for this row.
    var onAdd: () -> Void
}

struct PostRowView: View {
    let row: PostRowModel
    let isExpanded: Bool
    let imageStore: ChannelImageStore?
    var emoji: EmojiCatalogue?
    let onToggleExpanded: () -> Void
    /// Nil = no menu (the pre-T35 rendering, used by previews and by any read-only host).
    var actions: PostRowActions? = nil
    /// T36: open this post's thread (the reply line's tap). Nil keeps the line non-interactive.
    var onOpenThread: (() -> Void)? = nil
    /// T37: press a pill, ask who reacted, add another. Nil keeps the read-only pills.
    var reactionActions: PostRowReactionActions? = nil
    /// T38: what the attachment section may do — open the gallery, open a file preview, download.
    /// Nil keeps the drawn-but-inert rendering (a preview host, or the web render of the pane).
    var attachmentActions: PostRowAttachmentActions? = nil
    /// T41: a tap on the author's avatar opens that account's profile. Nil keeps the avatar inert —
    /// a preview host, the thread host that has not been wired yet, and every host while the
    /// `profile` surface resolves web.
    var onShowProfile: ((String) -> Void)? = nil

    private var showsHeader: Bool { !row.isGrouped && !row.isSystem }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            gutter
            VStack(alignment: .leading, spacing: 4) {
                if showsHeader { header }
                if row.isSystem {
                    systemMessage
                } else if row.isDeleted {
                    deletedTombstone
                } else {
                    body(for: row)
                    attachments
                    reactions
                    replyLine
                }
                if row.isPending { sendingStatus }
            }
            if let actions, actions.hasAnyAction, !row.isSystem, !row.isDeleted, !row.isPending {
                optionsButton(actions)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, row.isGrouped ? 2 : 6)
        // One row is one accessibility container: VoiceOver reads author + body in order and the
        // tests can still resolve the leaves inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("post.\(row.id)")
    }

    /// The row's actions, behind a visible button.
    ///
    /// T35 originally put them in a `.contextMenu` (long press). The live suite proved that
    /// unreachable: on iOS 26 a long press on a row lands in the body's `Text` and opens the
    /// **system** Copy/Share menu, so the app's own items never appeared (`docs/t35-build-note.md`
    /// §11). A visible overflow button is also the upstream idiom — mattermost-mobile opens a post
    /// options sheet when the reader taps a post (`app/components/post/index.tsx` → `PostOptions`).
    private func optionsButton(_ actions: PostRowActions) -> some View {
        Button {
            actions.onShowOptions()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message actions")
        .accessibilityIdentifier("post.\(row.id).menu")
    }

    /// The status of an optimistic row. It is drawn *under* the body rather than as a badge so the
    /// message stays readable at the moment it is least settled.
    private var sendingStatus: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text("Sending…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("post.\(row.id).pending")
    }

    /// The 36 pt avatar column. A grouped row has no avatar, so it shows its time in that column
    /// instead — that is what keeps a run of messages from the same author aligned.
    @ViewBuilder
    private var gutter: some View {
        if showsHeader {
            if let onShowProfile {
                // T41: the avatar is the profile affordance, as it is in the web client and in
                // upstream's `app/components/post/avatar`. A row with no host callback keeps the plain
                // drawing (a preview, or the surface resolving web).
                Button {
                    onShowProfile(row.author.id)
                } label: {
                    PostAvatarView(author: row.author)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.author.displayName) profile")
                .accessibilityIdentifier("post.\(row.id).avatar")
            } else {
                PostAvatarView(author: row.author)
            }
        } else if row.isSystem {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)
        } else {
            Text(timeTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.author.displayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .accessibilityIdentifier("post.\(row.id).author")
            Text(timeTitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if row.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
                    // T48: the socket test reads the pin a *second* client set from here — the row
                    // must move without a reload, and a label alone is not addressable.
                    .accessibilityIdentifier("post.\(row.id).pinned")
            }
            if row.isEdited {
                Text("(edited)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("post.\(row.id).edited")
            }
            Spacer(minLength: 0)
        }
    }

    private var timeTitle: String {
        PostListDerivation.timeTitle(for: row.post.createAt,
                                     calendar: .current,
                                     locale: .current,
                                     timeZone: .current)
    }

    @ViewBuilder
    private func body(for row: PostRowModel) -> some View {
        let blocks = row.showsAllBlocks(expanded: isExpanded) ? row.blocks : row.blocksToShow
        VStack(alignment: .leading, spacing: 6) {
            // No identifier on this container: SwiftUI merges sibling `Text`s into one accessibility
            // element, so an identifier here would swallow the "(edited)" marker and the fold button
            // below it (that is exactly what made the first UI run unable to find them).
            MarkdownView(blocks: blocks, identifierPrefix: "post.\(row.id).body", emoji: emoji)
            if row.isEdited && row.isGrouped {
                // A grouped row has no header, so the "(edited)" that lives there would be lost.
                // Upstream simply omits it on a grouped row; hiding the fact that a message changed is
                // worse than one extra muted word (docs/t34-build-note.md §10).
                Text("(edited)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("post.\(row.id).edited")
            }
            if row.fold != nil {
                if !isExpanded && !row.foldSummary.isEmpty {
                    // What the fold is hiding. Upstream says nothing and simply clips the height, so
                    // a reader cannot tell a 5-line trim from a 5,000-line one.
                    Text(row.foldSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("post.\(row.id).foldSummary")
                }
                Button(isExpanded ? "Show less" : "Show more") { onToggleExpanded() }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("post.\(row.id).showMore")
            }
        }
    }

    private var systemMessage: some View {
        Text(row.post.message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("post.\(row.id).system")
    }

    private var deletedTombstone: some View {
        Text("This message was deleted.")
            .font(.system(size: 15))
            .italic()
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("post.\(row.id).deleted")
    }

    // MARK: Reply line (T36, S13)

    /// The thread affordance every collapsed-thread client draws under a root: the people in the
    /// thread, then "N replies". Upstream puts this on the root's body (`post/body/reply_count`),
    /// tapping it opens the thread — which is the only way into a reply from the centre timeline,
    /// since a reply is deliberately not a row there (`ChannelViewModel.isTimelineRow`).
    ///
    /// Nothing is drawn for a post with no replies, and the line is not a button when the host has no
    /// thread surface to open (a preview, or the web render of the pane).
    @ViewBuilder
    private var replyLine: some View {
        if row.replyCount > 0, let label = ThreadDerivation.replyLabel(row.replyCount) {
            if let onOpenThread {
                Button(action: onOpenThread) {
                    replyLineContent(label: label)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label). Open thread")
                .accessibilityValue("\(row.replyCount)")
                .accessibilityIdentifier("post.\(row.id).replyCount")
            } else {
                replyLineContent(label: label)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("post.\(row.id).replyCount")
            }
        }
    }

    private func replyLineContent(label: String) -> some View {
        HStack(spacing: 6) {
            if !row.participants.isEmpty {
                HStack(spacing: -7) {
                    ForEach(Array(row.participants.prefix(ThreadDerivation.participantLimit).enumerated()),
                            id: \.offset) { _, author in
                        PostParticipantAvatarView(author: author, size: 20)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            if onOpenThread != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var attachments: some View {
        if !row.attachments.isEmpty {
            // T38: the section is its own view (`UI/Native/Files/AttachmentViews.swift`): image grid,
            // file rows with type icons and sizes, placeholders, and the tap targets for the gallery
            // and the file preview. The row only says what may be opened.
            AttachmentSectionView(row: row, imageStore: imageStore, actions: attachmentActions)
        }
    }

    @ViewBuilder
    private var reactions: some View {
        if !row.reactions.isEmpty {
            ReactionBarView(rowID: row.id,
                            reactions: row.reactions,
                            emoji: emoji,
                            actions: reactionActions)
        }
    }
}

// MARK: - Post options

/// The sheet a row's overflow button opens: what the reader can do with *this* message.
///
/// One sheet per window (`ChannelPostListView`/`ThreadPostListView` own it), so a list of 200 rows
/// does not build 200 sheets. The rows are exactly `PostOptionsCapabilities.offeredOptions` — one
/// ordered derivation (T48/S38) — so the sheet cannot draw an option the host cannot perform, and the
/// order is upstream's `post_options.tsx`.
///
/// The sheet **observes** the options model rather than taking a snapshot of the row's state, because
/// half of what decides the rows arrives after the first draw (`GET /roles/names`, the `flagged_post`
/// preferences) and the other half moves over the socket (a pin or a save from another client). A
/// plain value here would freeze "Save" on a post another device already saved.
///
/// Buttons carry stable identifiers (`postOptions.<action>`) because a UI test cannot press a menu item
/// it cannot name; the label is the same word, so VoiceOver reads what the test taps.
struct PostOptionsSheet: View {
    let rowID: String
    let authorName: String
    /// The row as it was when the sheet opened. Its id/author/message are immutable facts; the mutable
    /// ones (pinned, saved, following) come from `options`, which is observed.
    let row: PostRowModel
    let actions: PostRowActions
    let surface: PostOptionsSurface
    @ObservedObject var options: PostOptionsViewModel
    var onDismiss: () -> Void = {}

    /// The option whose write is in flight (sheet-local so the list's rows can be disabled one at a
    /// time without the model publishing mid-dismiss).
    @State private var pending: PostOptionID?
    /// A refused write, in the reader's words. The sheet stays open for it — a dismissed sheet with no
    /// message is exactly the "disabled row that does nothing" this card forbids.
    @State private var failure: String?
    /// The string this sheet put on the pasteboard **and then read back from it**. Showing it is how a
    /// test (and a reader) can tell the copy happened: the value is the pasteboard's, not the tap's.
    @State private var copied: String?

    private var offered: [PostOptionID] {
        options.offeredOptions(for: row, actions: actions, surface: surface)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HeaderRow(authorName: authorName)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                Section {
                    if offered.isEmpty {
                        // Not an option — a sentence. Nothing here can be pressed, so it cannot be a
                        // dead row.
                        Text("Nothing can be done with this message here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("postOptions.empty")
                    }
                    ForEach(offered, id: \.rawValue) { option in
                        row(for: option)
                    }
                }
                if let failure {
                    Section {
                        Text(failure)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("postOptions.error")
                    }
                }
                if let copied {
                    Section("Copied") {
                        Text(copied)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("postOptions.copied")
                    }
                    Section {
                        Button("Done") { onDismiss() }
                            .accessibilityIdentifier("postOptions.done")
                    }
                }
            }
            .navigationTitle("Message actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .accessibilityIdentifier("postOptions.cancel")
                }
            }
            .accessibilityIdentifier("postOptions.\(rowID)")
        }
        .presentationDetents([.medium, .large])
    }

    private func row(for option: PostOptionID) -> some View {
        Button(role: option.isDestructive ? .destructive : nil) {
            Task { await press(option) }
        } label: {
            HStack(spacing: 10) {
                Label(option.title, systemImage: option.glyph)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if pending == option {
                    ProgressView().controlSize(.mini)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(pending != nil)
        .accessibilityIdentifier(option.identifier)
    }

    /// Route one press to whoever can perform it.
    ///
    /// The four host options are the pane's own closures (they open the composer, the picker, a
    /// confirmation — no request of their own) and dismiss immediately, as they did before T48. The
    /// rest are requests on the options model; the sheet dismisses only when the request succeeded.
    private func press(_ option: PostOptionID) async {
        failure = nil
        switch option {
        case .react:
            onDismiss()
            actions.onReact()
            return
        case .reply:
            onDismiss()
            actions.onReply()
            return
        case .edit:
            onDismiss()
            actions.onEdit()
            return
        case .delete:
            onDismiss()
            actions.onDelete()
            return
        case .copyText, .copyLink, .save, .unsave, .pin, .unpin, .markUnread,
             .followThread, .unfollowThread:
            break
        }

        pending = option
        let outcome = await options.perform(option, row: row)
        pending = nil
        switch outcome {
        case .copied(let text):
            // The pasteboard is the effect: the model decided *what* the link is (from the server's own
            // team name), this puts it where the reader can paste it. The value is shown at once and
            // then verified on the next turn — UIPasteboard's write reaches the system pasteboard
            // asynchronously, so an immediate read-back can answer the *previous* string.
            UIPasteboard.general.string = text
            copied = text
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard UIPasteboard.general.string != text else { return }
                copied = nil
                failure = "Could not put this on the clipboard."
            }
        case .performed:
            onDismiss()
        case .failed(let message):
            failure = message
        }
    }

    private struct HeaderRow: View {
        let authorName: String
        var body: some View {
            Text(authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("postOptions.author")
        }
    }
}

// MARK: - Emoji glyph

/// One emoji as the reaction bar draws it: the server's image for a custom name, the Unicode
/// character for a built-in one, and the literal `:name:` when neither is known.
///
/// The catalogue is observed, for the same reason as `MarkdownInlineText`: `/emoji` and the image
/// bytes arrive after the reaction bar's first draw, and an unobserved `image(for:)` that answered
/// `nil` once would leave the reaction literal forever.
struct EmojiGlyph: View {
    let name: String
    var emoji: EmojiCatalogue?
    var size: CGFloat = 15

    var body: some View {
        if let emoji {
            CatalogueEmojiGlyph(name: name, catalogue: emoji, size: size)
        } else {
            EmojiGlyphContent(image: nil, name: name, size: size)
        }
    }
}

private struct CatalogueEmojiGlyph: View {
    let name: String
    @ObservedObject var catalogue: EmojiCatalogue
    var size: CGFloat

    private var key: String { name.lowercased() }

    var body: some View {
        EmojiGlyphContent(image: catalogue.images[key], name: name, size: size)
            .task(id: key) { _ = await catalogue.image(for: name) }
    }
}

private struct EmojiGlyphContent: View {
    let image: UIImage?
    let name: String
    let size: CGFloat

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Text(EmojiShortcodes.character(for: name) ?? ":\(name):")
                .font(.system(size: size))
        }
    }
}
