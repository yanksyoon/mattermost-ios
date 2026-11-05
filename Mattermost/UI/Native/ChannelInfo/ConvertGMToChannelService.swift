// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/channel.ts (`convertGroupMessageToPrivateChannel`: derive the name, POST,
//        then `switchToChannelById`), app/client/rest/channels.ts
//        (`POST /channels/{id}/convert_to_channel?team-id=`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §25; no
// upstream source copied. The protocol/implementation split is this repo's own (component-map.md §1),
// matching `ChannelCreationServing` (T47) and `ChannelFilesModels` (T52).
//
// Why a separate protocol instead of one more requirement on `ChannelInfoServing`: every existing fake
// (T40, T47, T52) implements that protocol in full, and a new *required* method is a compile error in
// test files this card does not own. `ChannelConversionServing` inherits it, so the production object is
// still `SessionChannelInfoService` — one client-resolution rule — and a test that wants the conversion
// fake implements one conformance.

import Foundation

/// What the "convert a group message" screen needs from one server.
@MainActor
protocol ChannelConversionServing: ChannelInfoServing {
    /// `POST /channels/{id}/convert_to_channel?team-id=` — the converted channel.
    ///
    /// Required, not defaulted: a fake that does not model the write must fail loudly rather than
    /// produce a green test in which nothing was sent (the T40-AV F1 failure mode).
    func convertGroupMessage(channelID: String,
                             teamID: String,
                             displayName: String,
                             name: String) async throws -> MMChannel
}

/// The production implementation: the same per-call client resolution `SessionChannelInfoService` uses
/// for every other channel-info call.
@MainActor
extension SessionChannelInfoService: ChannelConversionServing {
    func convertGroupMessage(channelID: String,
                             teamID: String,
                             displayName: String,
                             name: String) async throws -> MMChannel {
        try await client().convertGroupMessageToChannel(channelID: channelID,
                                                        teamID: teamID,
                                                        displayName: displayName,
                                                        name: name)
    }
}
