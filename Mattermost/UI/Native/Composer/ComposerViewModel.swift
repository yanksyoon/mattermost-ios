// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_draft/post_draft.tsx + send_handler/send_handler.ts (the send path: an
//        optimistic post with a `pending_post_id`, the server's answer replacing it, the text kept on
//        failure), app/components/post_draft/draft_handler (write/clear the draft), uploads/
//        (the attachment tray: one upload at a time per file, progress, cancel), app/components/
//        autocomplete/autocomplete.tsx (debounce, the per-source fetch, the stale-response guard),
//        app/screens/edit_post/edit_post.tsx (edit mode keeps the post id).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
// upstream source copied. The decomposition (one observable model, a service seam, a post sink) is
// this repo's own, matching `ChannelViewModel`/`ChannelListViewModel`.
//
// The five rules this object exists to hold, each pinned by a test in `T35ComposerViewModelTests`:
//   1. **Optimistic, then reconciled.** A send inserts a row whose id is a local `pending:<uuid>` and
//      whose `pending_post_id` is that same string. The server echoes that field on the socket
//      `posted` event, so the row is replaced by id — never by message text, never appended twice.
//   2. **Failure keeps the words.** Nothing is cleared until the server has answered. A failed send
//      leaves the text, the attachments and the draft on disk, and offers Retry.
//   3. **The draft is the durable record.** Written through on every change — no timer, so no window
//      a killed process can outlive; a change that lands while a write is running folds into one
//      follow-up — and flushed on demand (backgrounding), one row per (channel, thread root), in
//      T29's store — so it survives relaunch and a team switch. (The 400 ms debounce this replaced
//      was removed in T35's round 2: docs/t35-build-note.md §7.3.)
//   4. **Autocomplete cannot race itself.** Every keystroke bumps a generation; an answer for a
//      superseded term is dropped. The `@` list is restricted to the channel's members (server-side
//      `in_channel_id`, plus a client check when the member list is complete).
//   5. **Uploads are observable.** Progress comes from the transport's byte count, a cancel really
//      cancels the task, and a failed upload is retryable without losing the message.

import Foundation
import Combine

/// The list the composer writes into. Implemented by `ChannelViewModel` (the pane owns the rows).
@MainActor
protocol ComposerPostSink: AnyObject {
    /// Show an optimistic row now.
    func insertPendingPost(_ post: MMPost)
    /// Replace the optimistic row with the server's post (same message, real id).
    func confirmPendingPost(id: String, with post: MMPost)
    /// The send failed: take the optimistic row away, the words stay in the composer.
    func removePendingPost(id: String)
    /// An edit landed.
    func replacePost(_ post: MMPost)
    /// A delete landed: keep the row's slot and mark it (T34's tombstone rule).
    func tombstonePost(id: String)
    /// Did a post with this client id already arrive (over the socket) even though the request failed?
    func post(withPendingID pendingID: String) -> MMPost?
}

/// One composer per (channel, thread root).
@MainActor
final class ComposerViewModel: ObservableObject {

    // MARK: Types

    enum Phase: Equatable {
        case idle
        case sending
        /// The last attempt failed; the text is still here and `retry()` re-sends it.
        case failed(String)
    }

    enum Mode: Equatable {
        case newPost
        case reply(rootID: String)
        case editing(postID: String)

        var rootID: String {
            if case .reply(let rootID) = self { return rootID }
            return ""
        }

        var isEditing: Bool {
            if case .editing = self { return true }
            return false
        }
    }

    /// What `retry()` would re-run. Kept so a retry re-sends the *same* request (including its
    /// `pending_post_id`), which is what makes the reconcile-on-retry check possible.
    private enum PendingCommand {
        case create(ComposerPostBody, pendingID: String)
        case edit(postID: String, message: String)
    }

    // MARK: Published state

    @Published private(set) var text: String = ""
    /// The caret, as a UTF-16 offset (what `UITextView` reports).
    @Published private(set) var caret: Int = 0
    @Published private(set) var attachments: [ComposerAttachment] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var suggestions: [ComposerSuggestion] = []
    @Published private(set) var activeTrigger: ComposerTrigger?
    @Published private(set) var mode: Mode = .newPost
    @Published private(set) var isPreviewing = false
    /// A one-line note under the input ("Reply sent to the thread", "Message deleted") that clears
    /// itself; not an error.
    @Published private(set) var statusNote: String?
    /// The author's name when replying, as the banner draws it.
    @Published private(set) var replyTarget: String?
    /// True while the model is restoring the draft, so the view can hold the input back for one frame
    /// instead of flashing an empty composer.
    @Published private(set) var isRestoringDraft = false

    /// Whether the send button is enabled. An upload still in flight blocks the send: sending a file
    /// id that does not exist yet would post a message whose attachment never arrives.
    var canSend: Bool {
        guard phase != .sending, !isUploading else { return false }
        let body = ComposerMarkdownEditing.messageForSending(text)
        if mode.isEditing { return !body.isEmpty }
        return !body.isEmpty || attachments.contains(where: \.isUploaded)
    }

    var isUploading: Bool { attachments.contains(where: { $0.isUploading || $0.state == .queued }) }

    /// The attachment ids to post.
    var uploadedFileIDs: [String] { attachments.compactMap(\.fileID) }

    /// The draft key for the current mode. Editing has no draft (the post itself is the record).
    var draftRootID: String { mode.rootID }

    /// Who the composer writes as (the pane asks, so "edit" is only offered on my own post).
    var authorID: String? { myUserID }

    // MARK: Collaborators

    let channelID: String
    private let service: ComposerServing
    private let drafts: ComposerDraftStoring
    private weak var sink: ComposerPostSink?
    /// The pane's custom-emoji catalogue, when the channel has one: `:` completion offers the names
    /// the server actually owns.
    private let emojiCatalogue: EmojiCatalogue?
    private let now: () -> Date
    private let teamID: String?
    private let myUserID: String?

    /// How long the composer waits after a keystroke before it asks the server.
    private let autocompleteDebounce: Duration

    // MARK: Private state

    private var autocompleteGeneration = 0
    private var autocompleteTask: Task<Void, Never>?
    private var membershipTask: Task<ComposerMembership.MemberList, Never>?
    private var membership: ComposerMembership.MemberList?
    private var draftLeadTask: Task<Void, Never>?
    /// A draft write is running; changes that arrive meanwhile collapse into one follow-up.
    private var draftWriteInFlight = false
    private var draftWriteQueued = false
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    /// The bytes of an attachment that has not been uploaded yet, so Retry can re-send the same file
    /// without going back to the picker. Dropped as soon as the server has the file.
    private var uploadData: [UUID: Data] = [:]
    private var pendingCommand: PendingCommand?
    private var didRestoreDraft = false
    private var noteTask: Task<Void, Never>?

    // MARK: Init

    init(channelID: String,
         service: ComposerServing,
         drafts: ComposerDraftStoring,
         sink: ComposerPostSink? = nil,
         teamID: String? = nil,
         myUserID: String? = nil,
         emojiCatalogue: EmojiCatalogue? = nil,
         now: @escaping () -> Date = { Date() },
         autocompleteDebounce: Duration = .milliseconds(200)) {
        self.channelID = channelID
        self.service = service
        self.drafts = drafts
        self.sink = sink
        self.teamID = teamID
        self.myUserID = myUserID
        self.emojiCatalogue = emojiCatalogue
        self.now = now
        self.autocompleteDebounce = autocompleteDebounce
    }

    /// The pane attaches its model after construction (the coordinator's model is created before the
    /// view exists). Weak, because the list owns the composer's lifetime, not the other way round.
    func attach(sink: ComposerPostSink) {
        self.sink = sink
    }

    // MARK: - Text entry

    /// The view's single entry point for "the text changed" (typing, paste, dictation, a toolbar
    /// edit). Kept as one method so the trigger, the draft write and the caret can never disagree.
    func textChanged(_ newText: String, caret newCaret: Int) {
        let clamped = max(0, min(newCaret, (newText as NSString).length))
        text = newText
        caret = clamped
        // A failure is about the *previous* attempt; typing again starts a fresh try.
        if case .failed = phase { phase = .idle }
        scheduleDraftSave()
        refreshTrigger()
    }

    /// The caret moved without an edit (a tap, an arrow key).
    func caretMoved(to newCaret: Int) {
        let clamped = max(0, min(newCaret, (text as NSString).length))
        guard clamped != caret else { return }
        caret = clamped
        refreshTrigger()
    }

    private func refreshTrigger() {
        let trigger = ComposerTriggerParser.trigger(in: text, caret: caret)
        activeTrigger = trigger
        guard let trigger else {
            cancelAutocomplete()
            return
        }
        startAutocomplete(for: trigger)
    }

    /// Apply a chosen suggestion to the text and report the caret the view must place.
    @discardableResult
    func apply(_ suggestion: ComposerSuggestion) -> Int? {
        guard let trigger = activeTrigger else { return nil }
        guard let result = ComposerTriggerParser.apply(suggestion, to: text, trigger: trigger) else {
            // The text moved on since the list was drawn: drop the edit rather than apply it at an
            // offset that no longer means anything.
            cancelAutocomplete()
            return nil
        }
        text = result.text
        caret = result.caret
        cancelAutocomplete()
        scheduleDraftSave()
        return result.caret
    }

    /// Apply a markdown toolbar action; returns the selection the view must restore.
    func applyMarkdown(_ action: ComposerMarkdownAction, selection: NSRange) -> NSRange {
        let result = ComposerMarkdownEditing.apply(action, text: text, selection: selection)
        text = result.text
        caret = result.selection.location + result.selection.length
        scheduleDraftSave()
        return result.selection
    }

    func togglePreview() {
        isPreviewing.toggle()
    }

    // MARK: - Autocomplete

    /// Where suggestions come from. Users and channels come over the network; emoji come from the
    /// built-in table plus the server's own list, so `:` is instant.
    private func startAutocomplete(for trigger: ComposerTrigger) {
        autocompleteGeneration += 1
        let generation = autocompleteGeneration
        autocompleteTask?.cancel()
        autocompleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.autocompleteDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, generation == self.autocompleteGeneration else { return }
            let suggestions = await self.candidates(for: trigger)
            guard !Task.isCancelled, generation == self.autocompleteGeneration else { return }
            self.suggestions = ComposerSuggestionRanking.ranked(suggestions, term: trigger.term)
        }
    }

    private func cancelAutocomplete() {
        autocompleteGeneration += 1
        autocompleteTask?.cancel()
        autocompleteTask = nil
        suggestions = []
        activeTrigger = nil
    }

    /// Drop the list without changing the text (Escape).
    func dismissSuggestions() {
        cancelAutocomplete()
    }

    private func candidates(for trigger: ComposerTrigger) async -> [ComposerSuggestion] {
        switch trigger.kind {
        case .mention:
            return await mentionCandidates(term: trigger.term)
        case .channel:
            return await channelCandidates(term: trigger.term)
        case .emoji:
            return emojiCandidates(term: trigger.term)
        }
    }

    private func mentionCandidates(term: String) async -> [ComposerSuggestion] {
        var suggestions: [ComposerSuggestion] = []
        // `@channel` / `@here` / `@all` are addresses, not people: they are offered first when the
        // typed term matches them, the way upstream's `at_mention` list does.
        for special in ["channel", "here", "all"] where term.isEmpty || special.hasPrefix(term.lowercased()) {
            suggestions.append(ComposerSuggestion(kind: .specialMention,
                                                  value: special,
                                                  label: "@\(special)",
                                                  detail: "Notify everyone who can see this channel",
                                                  insertion: mentionInsertion(special),
                                                  glyph: "megaphone"))
        }
        guard !term.isEmpty else { return suggestions }
        let users = (try? await service.users(term: term,
                                              channelID: channelID,
                                              teamID: teamID,
                                              limit: 20)) ?? []
        let candidates = users
            .filter { !$0.id.isEmpty && $0.deleteAt == 0 && !$0.username.isEmpty }
            .map { user -> ComposerSuggestion in
                ComposerSuggestion(kind: .user,
                                   value: user.username,
                                   label: displayName(for: user),
                                   detail: "@\(user.username)",
                                   insertion: mentionInsertion(user.username),
                                   glyph: nil,
                                   // The membership check is by id: the member list is a set of
                                   // user ids, while `value` is the username that gets typed.
                                   userID: user.id)
            }
        guard !candidates.isEmpty else { return suggestions }
        let members = await memberListIfNeeded()
        return suggestions + ComposerMembership.filter(candidates, members: members)
    }

    /// The member list is fetched at most once per composer, and a failure leaves it unknown (which
    /// means "do not filter") rather than empty (which would hide every name).
    private func memberListIfNeeded() async -> ComposerMembership.MemberList {
        if let membership { return membership }
        if let running = membershipTask { return await running.value }
        let task = Task { [service, channelID] in
            (try? await service.channelMembers(channelID: channelID)) ?? .unknown
        }
        membershipTask = task
        let list = await task.value
        membership = list
        membershipTask = nil
        return list
    }

    private func channelCandidates(term: String) async -> [ComposerSuggestion] {
        guard !term.isEmpty, let teamID, !teamID.isEmpty else { return [] }
        let channels = (try? await service.channels(term: term, teamID: teamID, limit: 20)) ?? []
        return channels
            .filter { !$0.id.isEmpty && !$0.name.isEmpty && $0.deleteAt == 0 }
            .map { channel in
                ComposerSuggestion(kind: .channel,
                                   value: channel.name,
                                   label: "#\(channel.displayName.isEmpty ? channel.name : channel.displayName)",
                                   detail: channel.type == "O" ? "Public channel" : "Private channel",
                                   insertion: channelInsertion(channel.name),
                                   glyph: nil)
            }
    }

    private func emojiCandidates(term: String) -> [ComposerSuggestion] {
        let needle = term.lowercased()
        var suggestions: [ComposerSuggestion] = []
        for (name, glyph) in EmojiShortcodes.table {
            guard needle.isEmpty || name.contains(needle) else { continue }
            suggestions.append(ComposerSuggestion(kind: .emoji,
                                                  value: name,
                                                  label: "\(glyph) \(name)",
                                                  detail: "Emoji",
                                                  insertion: emojiInsertion(name),
                                                  glyph: glyph))
        }
        let customNames: [String] = emojiCatalogue.map { Array($0.identifiers.keys) } ?? []
        for name in customNames where needle.isEmpty || name.contains(needle) {
            suggestions.append(ComposerSuggestion(kind: .emoji,
                                                  value: name,
                                                  label: ":\(name):",
                                                  detail: "Custom emoji",
                                                  insertion: emojiInsertion(name),
                                                  glyph: nil))
        }
        // A shortcode list is not an identity: duplicates (a custom emoji named `smile`) collapse to
        // one row, the built-in first.
        var seen: Set<String> = []
        return suggestions.filter { seen.insert($0.id).inserted }
    }

    private func displayName(for user: MMUser) -> String {
        if !user.nickname.isEmpty { return user.nickname }
        let combined = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? user.username : combined
    }

    // MARK: - Attachments

    /// Add a picked file and start uploading it immediately (upstream starts on pick; the tray shows
    /// the progress, and the send button waits for it).
    func add(_ upload: ComposerUpload) {
        let attachment = ComposerAttachment(id: upload.id,
                                            filename: upload.safeFilename,
                                            mimeType: upload.mimeType,
                                            sizeBytes: upload.sizeBytes,
                                            state: .queued)
        attachments.append(attachment)
        uploadData[upload.id] = upload.data
        startUpload(upload)
    }

    private func startUpload(_ upload: ComposerUpload) {
        setState(.uploading(progress: 0), for: upload.id)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let progressHandler: @Sendable (Int64, Int64) -> Void = { sent, expected in
                    guard expected > 0 else { return }
                    let fraction = min(1, max(0, Double(sent) / Double(expected)))
                    Task { @MainActor [weak self] in
                        self?.setProgress(fraction, for: upload.id)
                    }
                }
                let file = try await self.service.upload(upload,
                                                        channelID: self.channelID,
                                                        onProgress: progressHandler)
                self.finishUpload(upload, with: file)
            } catch {
                if case MMError.cancelled = error {
                    // A cancel already set the state; do not overwrite it with a failure.
                    self.uploadTasks[upload.id] = nil
                    return
                }
                self.setState(.failed(ComposerErrorCopy.message(for: error)), for: upload.id)
                self.uploadTasks[upload.id] = nil
            }
        }
        uploadTasks[upload.id] = task
    }

    private func finishUpload(_ upload: ComposerUpload, with file: MMFileInfo) {
        guard let index = attachments.firstIndex(where: { $0.id == upload.id }) else {
            // The attachment was removed while the request was in flight: the server now holds an
            // orphan file. It is not attached to any post, so it is harmless — deleting it would
            // require a second request the user did not ask for.
            uploadTasks[upload.id] = nil
            return
        }
        attachments[index].state = .uploaded(fileID: file.id)
        // The server renames a file whose name collides, so the tray shows what the post will show.
        if !file.name.isEmpty { attachments[index].filename = file.name }
        if file.size > 0 { attachments[index].sizeBytes = file.size }
        uploadTasks[upload.id] = nil
        uploadData[upload.id] = nil
        scheduleDraftSave()
    }

    private func setProgress(_ fraction: Double, for id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              case .uploading = attachments[index].state else { return }
        attachments[index].state = .uploading(progress: fraction)
    }

    private func setState(_ state: ComposerAttachment.State, for id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    /// Cancel an in-flight upload. The task is cancelled, so the request really stops (the transport
    /// maps `URLError.cancelled` to `MMError.cancelled`), and the row offers Retry instead of
    /// pretending the file is on the server.
    func cancelUpload(id: UUID) {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        switch attachments[index].state {
        case .uploaded:
            return      // nothing to cancel; the bytes are already on the server
        case .queued:
            attachments.remove(at: index)
        case .uploading, .failed:
            attachments[index].state = .failed("Upload cancelled")
        }
    }

    /// Retry a failed or cancelled upload with the same bytes, which the composer kept for exactly
    /// this reason (a failed upload that cannot be retried would force the person to pick the file
    /// again — and on iOS that means going back through the picker).
    func retryUpload(id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        guard let data = uploadData[id] else { return }
        let attachment = attachments[index]
        let upload = ComposerUpload(id: id, filename: attachment.filename,
                                    mimeType: attachment.mimeType, data: data)
        startUpload(upload)
    }

    /// Remove an attachment from the tray. An uploaded one keeps its orphan file on the server (it is
    /// attached to no post); the send simply will not reference it.
    func removeAttachment(id: UUID) {
        cancelUpload(id: id)
        uploadData[id] = nil
        attachments.removeAll { $0.id == id }
        scheduleDraftSave()
    }

    // MARK: - Send / edit / delete

    /// Send the current mode. Safe to call twice: the second call is refused while `phase == .sending`.
    func send() async {
        guard canSend else { return }
        let body = ComposerMarkdownEditing.messageForSending(text)
        switch mode {
        case .editing(let postID):
            await performEdit(postID: postID, message: body)
        case .newPost, .reply:
            await performCreate(body: body)
        }
    }

    private func performCreate(body: String, pendingID reuse: String? = nil) async {
        let fileIDs = uploadedFileIDs
        let rootID = mode.rootID
        // A retry re-sends **the same** client id: a server that echoed the first attempt (whose
        // answer was lost) then knows it is the same message, and the list's reconcile-by-id path
        // cannot end up with two rows for one post.
        let pendingID = reuse ?? "pending:\(UUID().uuidString)"
        let request = ComposerPostBody(channelId: channelID,
                                       message: body,
                                       rootId: rootID.isEmpty ? nil : rootID,
                                       fileIds: fileIDs.isEmpty ? nil : fileIDs,
                                       pendingPostId: pendingID)
        pendingCommand = .create(request, pendingID: pendingID)
        phase = .sending

        // The optimistic row. `createAt` is the local clock: it sorts the row to the bottom, which is
        // where a just-sent message belongs even if the device clock is a little off the server's.
        let optimistic = MMPost(id: pendingID,
                                createAt: ComposerDraft.now(now()),
                                userId: myUserID ?? "",
                                channelId: channelID,
                                rootId: rootID,
                                message: body,
                                fileIds: fileIDs,
                                pendingPostId: pendingID)
        // A reply is not in the channel's list (that is the thread pane, T36), so it is not inserted:
        // an optimistic row that can never be reconciled would be a permanent phantom.
        if rootID.isEmpty { sink?.insertPendingPost(optimistic) }

        do {
            let created = try await service.createPost(request)
            sink?.confirmPendingPost(id: pendingID, with: created)
            finishSuccessfully(note: rootID.isEmpty ? nil : "Reply sent to the thread")
        } catch {
            sink?.removePendingPost(id: pendingID)
            phase = .failed(ComposerErrorCopy.message(for: error))
            // Persist *now*: the failure is exactly the moment the words matter most, and the debounce
            // may not have fired since the last keystroke.
            await saveDraftNow()
        }
    }

    private func performEdit(postID: String, message: String) async {
        guard !message.isEmpty else { return }
        pendingCommand = .edit(postID: postID, message: message)
        phase = .sending
        do {
            let updated = try await service.patchPost(id: postID,
                                                      message: message,
                                                      fileIDs: originalFileIDs)
            sink?.replacePost(updated)
            finishSuccessfully(note: "Message updated", keepMode: false)
        } catch {
            phase = .failed(ComposerErrorCopy.message(for: error))
        }
    }

    /// Delete one of my posts. The row is not removed: it keeps its slot as a tombstone, which is what
    /// a reader watching the conversation expects (the same rule the socket's `post_deleted` applies).
    func delete(postID: String) async {
        do {
            try await service.deletePost(id: postID)
            sink?.tombstonePost(id: postID)
            show(note: "Message deleted")
        } catch {
            show(note: ComposerErrorCopy.message(for: error))
        }
    }

    /// Retry the last failed command. If the post actually landed (the socket echo carries the client
    /// id) it is treated as a success instead of being sent twice — the failure mode a blind retry has.
    func retry() async {
        guard case .failed = phase, let command = pendingCommand else { return }
        if case .create(_, let pendingID) = command, let landed = sink?.post(withPendingID: pendingID) {
            sink?.confirmPendingPost(id: pendingID, with: landed)
            finishSuccessfully(note: nil)
            return
        }
        switch command {
        case .create(_, let pendingID):
            await performCreate(body: ComposerMarkdownEditing.messageForSending(text),
                                pendingID: pendingID)
        case .edit(let postID, _):
            await performEdit(postID: postID, message: ComposerMarkdownEditing.messageForSending(text))
        }
    }

    private func finishSuccessfully(note: String?, keepMode: Bool = false) {
        let draftRoot = draftRootID
        phase = .idle
        pendingCommand = nil
        text = ""
        caret = 0
        attachments = []
        uploadData.removeAll()
        suggestions = []
        activeTrigger = nil
        if !keepMode {
            mode = .newPost
            replyTarget = nil
        }
        isPreviewing = false
        didRestoreDraft = false
        Task { await self.drafts.delete(channelID: self.channelID, rootID: draftRoot) }
        if let note { show(note: note) }
    }

    private func show(note: String) {
        statusNote = note
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.statusNote = nil
        }
    }

    /// Edit mode: the composer holds another post's text. The post's own file ids are preserved and
    /// sent back unchanged, because `PUT /posts/{id}` replaces the list rather than merging it.
    private var originalFileIDs: [String] = []

    func beginEditing(_ post: MMPost) {
        mode = .editing(postID: post.id)
        text = post.message
        caret = (post.message as NSString).length
        originalFileIDs = post.fileIds
        attachments = []
        suggestions = []
        activeTrigger = nil
        replyTarget = nil
        phase = .idle
    }

    /// Reply mode: the next send carries `root_id`.
    func beginReply(to post: MMPost, authorLabel: String) {
        mode = .reply(rootID: post.id)
        replyTarget = authorLabel
        phase = .idle
        text = ""
        caret = 0
        attachments = []
        didRestoreDraft = false
        Task { await restoreDraftIfNeeded() }
    }

    /// Leave edit / reply mode. The text is dropped when switching *modes* (a thread's draft is not
    /// the channel's), which is why the current draft is written first.
    func cancelMode() async {
        await saveDraftNow()
        mode = .newPost
        replyTarget = nil
        originalFileIDs = []
        text = ""
        caret = 0
        attachments = []
        phase = .idle
        pendingCommand = nil
        didRestoreDraft = false
        await restoreDraftIfNeeded()
    }

    // MARK: - Drafts

    /// Read the draft for the current mode once. The view calls this when it appears; repeated calls
    /// are cheap and do not clobber text the user has typed since.
    func restoreDraftIfNeeded() async {
        guard !didRestoreDraft else { return }
        didRestoreDraft = true
        isRestoringDraft = true
        defer { isRestoringDraft = false }
        guard let draft = await drafts.load(channelID: channelID, rootID: draftRootID) else { return }
        // Only fill an empty composer: a draft that lands after the person has started typing must not
        // replace their words.
        guard text.isEmpty, attachments.isEmpty else { return }
        text = draft.message
        caret = (draft.message as NSString).length
        attachments = draft.files.map { file in
            ComposerAttachment(id: UUID(),
                               filename: file.name,
                               mimeType: file.mimeType,
                               sizeBytes: file.size,
                               state: .uploaded(fileID: file.id))
        }
    }

    /// Write the draft now (backgrounding, mode switch, a failed send).
    func saveDraftNow() async {
        draftLeadTask?.cancel()
        draftLeadTask = nil
        draftWriteInFlight = false
        draftWriteQueued = false
        await writeDraftSnapshot()
    }

    /// The one write: whatever the text is *at the moment it runs*.
    ///
    /// T35 run 124: the draft used to be written only after `draftDebounce` of quiet, so a process
    /// death inside that window lost the text — measured against a real relaunch (the app's SQLite
    /// file had an empty `draft` table after typing and killing it, and a later run restored the
    /// first *character* only, because that was the sole write that had landed).
    ///
    /// The card's rule is "the text is never lost", so the write is now **write-through with
    /// coalescing**, not timer-based: every change writes immediately, and a change that arrives
    /// while a write is still running folds into exactly one follow-up write that carries the
    /// *latest* text. There is no window in which a keystroke exists only in memory for longer than
    /// one store round-trip, and a fast typist still cannot queue one write per keystroke.
    private func scheduleDraftSave() {
        if draftWriteInFlight {
            draftWriteQueued = true
            return
        }
        draftWriteInFlight = true
        draftLeadTask = Task { [weak self] in
            guard let self else { return }
            await self.writeDraftSnapshot()
            self.draftWriteInFlight = false
            self.draftLeadTask = nil
            if self.draftWriteQueued {
                self.draftWriteQueued = false
                self.scheduleDraftSave()
            }
        }
    }

    private func writeDraftSnapshot() async {
        let draft = ComposerDraft(channelID: channelID,
                                  rootID: draftRootID,
                                  message: text,
                                  files: attachments.compactMap(storedFile),
                                  updateAt: ComposerDraft.now(now()))
        if draft.isEmpty {
            await drafts.delete(channelID: channelID, rootID: draftRootID)
        } else {
            await drafts.save(draft)
        }
    }

    private func storedFile(_ attachment: ComposerAttachment) -> ComposerStoredFile? {
        guard let fileID = attachment.fileID else { return nil }
        return ComposerStoredFile(id: fileID,
                                  name: attachment.filename,
                                  mimeType: attachment.mimeType,
                                  size: attachment.sizeBytes)
    }

    // MARK: - Diagnostics

    /// Tests only: how much of the send flow is in flight.
    var hasPendingCommand: Bool { pendingCommand != nil }
    var suggestionTermsRequested: Int { autocompleteGeneration }
}

// MARK: - Error copy

/// The composer's own wording. A send failure is not a page-load failure: the reader needs to know
/// their words are safe and what to do next, not which URL failed.
enum ComposerErrorCopy {
    static func message(for error: Error) -> String {
        guard let mm = error as? MMError else {
            return "The message could not be sent. Your text is still here — try again."
        }
        switch mm {
        case .offline:
            return "You are offline. The message is saved and will be here when you are back."
        case .timeout:
            return "The server did not answer. Your text is still here — try again."
        case .unauthorized:
            return "Your session has expired. Sign in again to send this message."
        case .forbidden:
            return "You do not have permission to post in this channel."
        case .notFound:
            return "This channel no longer exists."
        case .rateLimited:
            return "You are sending too quickly. Wait a moment and try again."
        case .cancelled:
            return "Cancelled."
        case .server(_, let message), .client(_, let message):
            if let message, !message.isEmpty { return message }
            return "The server refused the message. Try again."
        default:
            return mm.errorDescription ?? "The message could not be sent."
        }
    }
}
