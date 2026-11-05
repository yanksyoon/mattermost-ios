// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_draft/typing/index.tsx (the row: a list of typists, one name per person,
//        "X is typing..." / "A and B are typing...", at most three names, the whole row hidden when
//        nobody is typing), app/actions/websocket/users.ts:91-127 (a frame is **received**, the
//        author is resolved to a display name, and a TimeBetweenUserTypingUpdatesMilliseconds timer
//        re-emits the stop for that exact arrival).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §24; no
// upstream source copied.
//
// The decomposition is this repo's own, matching `ComposerDraftStore`/`EmojiCatalogue`: one small
// observable object per pane, fed by the pane's socket handler, observed only by the view that draws
// the row. Two rules are worth stating because they are the ones a naive port gets wrong:
//
//  1. **A frame is a heartbeat, not a state.** The server sends no "stopped typing" event at all
//     (measured: `scripts/t4f_typing_probe.py` — only `typing` frames, and the sender is omitted from
//     its own broadcast). A typist stays on screen for the server's interval after their **last**
//     frame, and each new frame re-arms that window. That is why an entry keyed by user id carries a
//     generation: a stop scheduled by an older frame must not remove the newer one.
//  2. **Thread and channel are different rows.** Upstream's row filters on
//     `(msg.parentId || msg.rootId || '') === rootId`, so a channel composer's row ignores thread
//     frames and a thread's row ignores channel frames. `accepts(_:)` is that comparison, and it is
//     the reason the pane's socket handler cannot simply forward every `.typing` event to both.

import Foundation

/// The sentence the row draws — upstream's `msg_typing.isTyping` / `msg_typing.areTyping`.
enum TypingLabel {

    /// Upstream spells the empty case out of the i18n file with an empty `{user}`; showing
    /// " is typing…" to a reader would be a bug, so an unnamed typist is "Someone" until the profile
    /// request lands (the pane updates the entry through `rename(userID:name:)`).
    static let unnamed = "Someone"

    /// Upstream keeps at most three names: `nextTyping.splice(3)`, then the last of those is the
    /// named one, so "A, B and C are typing…" never grows past the two names it joins.
    static let maximumNames = 3

    /// `nil` when nobody is typing — the row draws nothing at all, not an empty line.
    static func sentence(_ names: [String]) -> String? {
        let cleaned = names.map { name -> String in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? unnamed : trimmed
        }
        let shown = Array(cleaned.prefix(maximumNames))
        switch shown.count {
        case 0:
            return nil
        case 1:
            return "\(shown[0]) is typing..."
        default:
            let named = shown.dropLast().joined(separator: ", ")
            return "\(named) and \(shown[shown.count - 1]) are typing..."
        }
    }
}

/// One pane's typing row: who is typing, and until when.
///
/// Not a `@Published` property of the pane model on purpose: SwiftUI does not observe a nested
/// `ObservableObject` through its owner, and the row has to redraw while the rest of the post list
/// stays still. `ComposerView` observes this object directly.
@MainActor
final class TypingIndicator: ObservableObject {

    /// One typist, in the order they were last heard from (upstream re-appends on every frame, so the
    /// most recent typist is the one named last).
    private struct Entry {
        let userID: String
        var name: String
        var generation: Int
        var order: Int
    }

    /// The channel this row belongs to.
    private(set) var channelID: String
    /// `""` for a channel composer, the thread's root post id for a thread composer. The frame's
    /// `parent_id` is compared against exactly this value.
    let parentID: String

    /// How long a received frame stays on screen — the server's
    /// `TimeBetweenUserTypingUpdatesMilliseconds`. Settable because the pane learns it from
    /// `/config/client` after the model is built (see `ChannelViewModel.typingSettingsLoaded`); the
    /// value only affects frames received after the change, which is the honest reading of "the
    /// server's window".
    var expiry: TimeInterval

    /// Diagnostics/tests: how many frames this row accepted.
    private(set) var receivedCount = 0

    @Published private(set) var names: [String] = []

    /// The row's text, or `nil` when nobody is typing.
    var label: String? { TypingLabel.sentence(names) }

    private let clock: SocketClock
    private var entries: [String: Entry] = [:]
    private var order = 0
    private var timers: [String: Task<Void, Never>] = [:]

    init(channelID: String,
         parentID: String,
         expiry: TimeInterval = MMTypingSettings.default.interval,
         clock: SocketClock = SystemSocketClock()) {
        self.channelID = channelID
        self.parentID = parentID
        self.expiry = expiry
        self.clock = clock
    }

    /// Whether a socket frame belongs to this row — upstream's `channelId` + `parentId` comparison.
    ///
    /// `parent_id` is `""` in a `typing` frame for a channel message and the thread root's id for a
    /// reply (measured on 9.11.19: a frame whose `parent_id` key is omitted arrives as `""`).
    func accepts(_ typing: SocketTyping) -> Bool {
        typing.channelID == channelID && typing.parentID == parentID
    }

    /// The thread pane can be opened from a permalink, which carries no channel: its row exists before
    /// the root names one, and a frame that arrived meanwhile was judged against `""`. Retarget the
    /// comparison and drop anybody listed — they belonged to the wrong comparison, not to this thread.
    func retarget(channelID: String) {
        guard !channelID.isEmpty, channelID != self.channelID else { return }
        self.channelID = channelID
        clear()
    }

    /// A frame arrived: show `userID` (with the best name the pane has) for another `expiry` seconds.
    ///
    /// An empty user id is the server's own "nobody" and is refused rather than drawn as a blank
    /// typist.
    func receive(userID: String, name: String?) {
        guard !userID.isEmpty else { return }
        receivedCount += 1
        order += 1
        let previous = entries[userID]
        let generation = (previous?.generation ?? 0) + 1
        entries[userID] = Entry(userID: userID,
                                name: name ?? previous?.name ?? "",
                                generation: generation,
                                order: order)
        // The frame is a heartbeat: re-arm this user's window instead of stacking a second one, so a
        // typist who keeps talking cannot disappear between two frames.
        timers[userID]?.cancel()
        let window = expiry
        timers[userID] = Task { [weak self, clock] in
            await clock.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.expire(userID: userID, generation: generation)
        }
        rebuild()
    }

    /// The author's profile landed after the frame did: name them without restarting their window.
    func rename(userID: String, name: String) {
        guard var entry = entries[userID], !name.isEmpty, entry.name != name else { return }
        entry.name = name
        entries[userID] = entry
        rebuild()
    }

    /// The pane went away, or the composer was switched: forget everybody now.
    func clear() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        entries.removeAll()
        order = 0
        if !names.isEmpty { names = [] }
    }

    private func expire(userID: String, generation: Int) {
        guard let entry = entries[userID], entry.generation == generation else { return }
        entries[userID] = nil
        timers[userID] = nil
        rebuild()
    }

    private func rebuild() {
        names = entries.values
            .sorted { $0.order < $1.order }
            .map(\.name)
    }
}
