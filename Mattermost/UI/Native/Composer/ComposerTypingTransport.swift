// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/websocket/users.ts:124-127 (`userTyping` → `client?.sendUserTypingEvent(
//        channelId, rootId)`), app/client/websocket/index.ts:461-466 (`sendUserTypingEvent` sends
//        `user_typing` with `{channel_id, parent_id}`), app/components/post_draft/post_input/index.ts
//        (the two config values the gate reads).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §24; no
// upstream source copied.
//
// Why a seam rather than a call inside the composer:
//  - the **send** is the app's one socket per server (`TeamSidebarCoordinator`), not a REST call, so
//    it must not be reached from `ComposerServing` — that protocol is the REST surface and a fake
//    server has no socket;
//  - the **settings** come from `/config/client`, which the composer must be able to fail to read
//    (offline, a proxy that strips the route) without silencing the whole write surface;
//  - and both are exactly the parts the unit suite has to script: "the server says typing is off",
//    "the answer has not arrived yet", "the socket is gone".

import Foundation

/// What a composer needs to announce typing: the server's own switch, and one frame on the app's
/// single socket for that server.
@MainActor
protocol ComposerTypingTransporting: AnyObject {
    /// The server's typing settings, or `nil` when the server could not be asked.
    ///
    /// Never throws and never invents: `nil` is "no answer", and the composer stays **silent** on it
    /// (`ComposerViewModel.announceTypingIfDue`) — a failed read must not become "typing is enabled,
    /// every five seconds", which is what returning the defaults here would mean.
    func settings() async -> MMTypingSettings?

    /// One `user_typing` frame. `parentID` is the thread root for a reply and `nil` for a channel
    /// message (the frame then carries no `parent_id`, which the server normalises to `""`).
    func sendTyping(channelID: String, parentID: String?) async
}

extension ComposerTypingTransporting {
    /// A double that only records sends has no config of its own, so it has no answer: silent.
    func settings() async -> MMTypingSettings? { nil }
}

/// The production transport: settings through the session's `APIClient` (ETag-cached), the frame
/// through the rail's socket.
///
/// The settings are read **once** and kept: `/config/client` is a document an admin changes rarely,
/// and a composer must not ask the server a question per keystroke. A failed read is not kept, so the
/// next attempt can still succeed.
@MainActor
final class SessionComposerTypingTransport: ComposerTypingTransporting {

    private let resolve: () -> APIClient?
    /// The frame's delivery. Wired to `TeamSidebarCoordinator.sendTyping` by the pane coordinators;
    /// deliberately silent on failure — a typing announcement is not worth an error banner, and the
    /// socket drops a frame sent while it is closed by design (`SocketClient.send`).
    private let deliver: (String, String?) async -> Void

    private var cached: MMTypingSettings?
    private var loadTask: Task<MMTypingSettings?, Never>?

    init(resolve: @escaping () -> APIClient?,
         deliver: @escaping (String, String?) async -> Void) {
        self.resolve = resolve
        self.deliver = deliver
    }

    /// The settings are read **once** and kept: `/config/client` is a document an admin changes rarely,
    /// and a composer must not ask the server a question per keystroke. A failed read is not kept
    /// (and answers `nil`), so the next attempt can still succeed.
    func settings() async -> MMTypingSettings? {
        if let cached { return cached }
        if let loadTask, let value = await loadTask.value {
            cached = value
            return value
        }
        let resolve = self.resolve
        let task = Task { () -> MMTypingSettings? in
            guard let client = resolve() else { return nil }
            return try? await client.typingSettings()
        }
        loadTask = task
        let value = await task.value
        loadTask = nil
        // A read that failed is not remembered: `nil` here means "ask again next time", while a real
        // answer (including "disabled") is kept for the life of the composer.
        if let value { cached = value }
        return value
    }

    func sendTyping(channelID: String, parentID: String?) async {
        await deliver(channelID, parentID)
    }
}
