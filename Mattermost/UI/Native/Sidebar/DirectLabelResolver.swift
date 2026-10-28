// Naming the direct-message rows of the channel sidebar.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
// `app/utils/channel.ts` (`getChannelName` / DM partner lookup), `app/screens/home/channel_list/...`
// and `app/actions/remote/channel.ts` (profiles are fetched by id batch and kept in the store, not
// per screen). Licence: Apache-2.0 — behaviour ported with attribution per
// docs/THIRD_PARTY_NOTICES.md §3; no upstream source copied.
//
// Why this is its own object rather than a function (card t_c0e42801):
//
// A 1:1 DM channel carries an EMPTY `display_name` — its `name` is `<userID>__<userID>` — so the
// row can only show a person's name if the profile is resolved. That resolution used to be one
// all-or-nothing step under a 10 s deadline: one `POST /users/ids` for every id at once, and when
// the deadline lost, the whole map was thrown away and *every* DM row in the list degraded to
// "Direct message". On a workspace with hundreds of channels that is exactly what happened.
//
// This resolver is incremental instead: it publishes the labels it can already name after every
// batch, so a deadline (or one failed request) costs only the rows still outstanding.

import Foundation

/// The names resolved so far for a sidebar's DM/GM rows.
struct DirectLabelMap: Equatable, Sendable {
    /// channel id → the row's label ("Ada Lovelace", "Ada Lovelace, Grace Hopper", "You").
    var labels: [String: String] = [:]
    /// channel id → every name a quick switcher may match the row by.
    var terms: [String: [String]] = [:]

    static let empty = DirectLabelMap()
}

/// Resolve the people in a set of DM/GM channels into row labels, a batch at a time.
///
/// Order of work, cheapest first:
///  1. **Profiles already in hand.** `profiles` (the per-server `UserProfileCache`) answers whoever
///     another screen has already fetched; on a warm session that is all of them and no request is
///     made at all.
///  2. **The rest, chunked.** At most `profileBatchSize` ids per `POST /users/ids`, merged as they
///     land. One oversized body was both slow and fragile; one failed chunk now costs only its own
///     ids.
///  3. **Group messages.** A GM's `name` is an opaque hash, so its member list has to be fetched
///     (`GET /channels/{id}/members`), eight channels at a time, and each batch's people are named
///     as soon as their profiles are in hand.
///
/// Everything is `@MainActor`, like the rest of the shell's screen state: the closure that publishes
/// progress is called on the main actor, between `await`s, never concurrently.
@MainActor
final class DirectLabelResolver {

    /// The largest id batch one `POST /users/ids` may carry. Chunking is what keeps a large
    /// workspace from turning the label step into the slowest request of the load.
    static let profileBatchSize = 100

    /// How many group channels have their member lists fetched at once.
    static let groupBatchSize = 8

    /// Upstream's own label for the conversation with yourself (`getChannelName`: a DM whose only
    /// participant is you reads "You", not an "id__id" key and not "Direct message").
    static let selfLabel = "You"

    private let client: APIClient
    private let userID: String?
    private let profiles: UserProfileCache?
    /// Called with the map resolved so far, each time it grows.
    private let onProgress: (DirectLabelMap) -> Void

    private var people: [String: MMUser] = [:]
    /// channel id → the *other* people in it (empty while a GM's members are unknown).
    private var memberIDsByChannel: [String: [String]] = [:]
    /// DMs whose only participant is the signed-in user (`<myid>__<myid>`).
    private var selfChannels: [String] = []
    private var groupChannels: [MMChannel] = []
    private(set) var published = DirectLabelMap.empty

    init(client: APIClient,
         userID: String?,
         profiles: UserProfileCache? = nil,
         onProgress: @escaping (DirectLabelMap) -> Void = { _ in }) {
        self.client = client
        self.userID = userID
        self.profiles = profiles
        self.onProgress = onProgress
    }

    /// Resolve `channels` and return the final map.
    func run(for channels: [MMChannel]) async -> DirectLabelMap {
        let directs = channels.filter { ChannelSidebarDerivation.kind(of: $0)?.isDirect == true }
        guard !directs.isEmpty else { return .empty }

        for channel in directs {
            switch ChannelSidebarDerivation.kind(of: channel) {
            case .directMessage:
                // The DM's name carries both participant ids, so no member call is needed.
                let parts = channel.name.components(separatedBy: "__").filter { !$0.isEmpty }
                let others = Array(Set(parts.filter { $0 != userID }))
                if others.isEmpty {
                    // Nobody but me in it. Only a name that really is "<me>__<me>" counts as a
                    // self-DM; anything else stays unlabelled rather than claiming to be "You".
                    if parts.count >= 2, parts.allSatisfy({ $0 == userID }) {
                        selfChannels.append(channel.id)
                    }
                } else {
                    memberIDsByChannel[channel.id] = others
                }
            case .groupMessage:
                groupChannels.append(channel)
            default:
                break
            }
        }

        // My own profile names the self-DM's search terms; the session already knows who I am.
        if let userID, people[userID] == nil, let me = profiles?.known(id: userID) {
            people[userID] = me
        }
        await resolve(Array(memberIDsByChannel.values.flatMap { $0 }))
        // Publish even when there was nothing to fetch: a self-DM needs no profile at all, and a
        // workspace whose every partner is already in hand has no request to hang the label on.
        publish()

        let client = self.client
        let myID = self.userID
        for batch in Self.batches(of: groupChannels, size: Self.groupBatchSize) {
            if Task.isCancelled { return published }
            await withTaskGroup(of: (String, [String]?).self) { group in
                for channel in batch {
                    group.addTask {
                        let members = try? await client.channelMembers(channelID: channel.id)
                        return (channel.id, members?.map(\.userId).filter { $0 != myID })
                    }
                }
                for await (channelID, ids) in group {
                    if let ids { memberIDsByChannel[channelID] = Array(Set(ids)) }
                }
            }
            // Name this batch's people now: whatever happens to the batches after it, these rows
            // are labelled.
            await resolve(batch.flatMap { memberIDsByChannel[$0.id] ?? [] })
        }
        return published
    }

    // MARK: - Steps

    /// Learn these ids' profiles: cache first, then chunked requests. Publishes after each step.
    private func resolve(_ ids: [String]) async {
        let unknown = Array(Set(ids)).filter { people[$0] == nil }
        guard !unknown.isEmpty else { return }
        guard let profiles else {
            await fetch(unknown)
            return
        }
        let cached = profiles.known(ids: unknown)
        for user in cached { people[user.id] = user }
        publish()
        let found = Set(cached.map(\.id))
        await fetch(unknown.filter { !found.contains($0) })
    }

    /// `POST /users/ids`, at most `profileBatchSize` ids at a time.
    ///
    /// A chunk that fails is skipped, not fatal: the rows it would have named stay unlabelled (which
    /// the list already draws), and the rows the other chunks named stay named.
    private func fetch(_ ids: [String]) async {
        for chunk in Self.batches(of: ids, size: Self.profileBatchSize) {
            if Task.isCancelled { return }
            guard let answer = try? await client.users(ids: chunk) else { continue }
            for user in answer where people[user.id] == nil { people[user.id] = user }
            // A profile this load paid for is remembered for the next screen and the next reload.
            profiles?.remember(answer)
            publish()
        }
    }

    /// Rebuild the map from what is known and hand it to the caller. Called after every step, so the
    /// map only ever grows — a deadline that fires mid-way keeps what has landed.
    private func publish() {
        var next = DirectLabelMap.empty
        for (channelID, ids) in memberIDsByChannel {
            let resolved = ids.compactMap { people[$0] }
            guard !resolved.isEmpty else { continue }
            next.labels[channelID] = resolved
                .map(Self.label(for:))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: ", ")
            next.terms[channelID] = resolved.flatMap(Self.searchTerms(for:))
        }
        for channelID in selfChannels {
            next.labels[channelID] = Self.selfLabel
            if let userID, let me = people[userID] { next.terms[channelID] = Self.searchTerms(for: me) }
        }
        guard next != published else { return }
        published = next
        onProgress(next)
    }

    static func batches<T>(of values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }

    // MARK: - Names

    /// The human name upstream shows for a person: nickname, else the full name, else the username.
    static func label(for user: MMUser) -> String {
        if !user.nickname.isEmpty { return user.nickname }
        let full = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return user.username
    }

    /// Every name a quick switcher may match this person by (`@ada`, `ada`, `Ada Lovelace`).
    static func searchTerms(for user: MMUser) -> [String] {
        var terms = [user.username, label(for: user)]
        if !user.firstName.isEmpty { terms.append(user.firstName) }
        let full = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { terms.append(full) }
        return terms.filter { !$0.isEmpty }
    }
}
