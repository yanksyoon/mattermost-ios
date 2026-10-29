// Author profiles for whatever a screen has on it, fetched the one way that cannot lose them all.
//
// Why this exists (card t_70b41028): every pane that draws a person's name keeps a map
// `userID -> MMUser` and fills it with `POST /users/ids`. Each of those panes had its own copy of
// the same five lines, and each copy had the same three defects:
//
//   1. **No empty-id filter.** A post's `user_id` can be `""` (system and join messages, and some
//      bot/plugin posts). One empty id in the body makes Mattermost refuse the whole request, so
//      the *entire* batch is lost and every author on screen reads "Unknown user". Whether a
//      channel broke therefore depended on whether it happened to contain one system post —
//      exactly the data-dependent shape the report had.
//   2. **No chunking.** Every distinct author id went into one body. A long page plus a few system
//      posts could exceed what the endpoint accepts, with the same all-or-nothing result.
//   3. **Errors were invisible.** `(try? await …) ?? []` made a 400/401/timeout indistinguishable
//      from "nobody to load", so the failure never showed up in a diagnostic.
//
// The repair is one loader with those three properties, shared by every caller instead of five
// divergent copies:
//
//   - ids are de-duplicated and empty ones are dropped **before** anything is asked (`clean`);
//   - a [UserProfileCache] is consulted first, so a person the channel timeline or the sidebar has
//     already fetched costs no request at all;
//   - the rest are fetched at most `size` ids per request, and **a chunk that fails is skipped, not
//     fatal** — the authors another chunk named stay named;
//   - the outcome is a [ProfileBatchReport] (requested / cached / sent / resolved / failed / error),
//     which is what the caller writes to a diagnostics line. Nothing is swallowed.
//
// The caller still owns what it did *not* learn: an author the server genuinely will not name (a
// deleted account) keeps its honest fallback ("Unknown user", or the `username` in `props`). This
// loader's promise is narrower and testable: it never *loses* a profile it was given, and it never
// turns one bad id into a lost page.

import Foundation

/// One author-profile load's numbers — the diagnostics line, and what the tests assert on.
struct ProfileBatchReport: Equatable {
    /// Distinct, non-empty ids the caller asked about.
    var requested = 0
    /// Ids answered from the profile cache, i.e. that cost no request.
    var cached = 0
    /// Ids actually sent to the server (requested − cached).
    var sent = 0
    /// Ids the caller ended up holding a profile for (cache hits + answered ids).
    ///
    /// This can be less than `requested` without an error: the server does not answer for an id it
    /// has no account for (deleted, or another instance's id). That gap is what a row's honest
    /// fallback is for.
    var resolved = 0
    /// How many requests were made.
    var chunks = 0
    /// Ids that were in a chunk the endpoint refused. Their authors stay unresolved; the others
    /// do not.
    var failed = 0
    /// The first failure's description, `nil` when every chunk answered.
    var error: String?

    /// `<pane> profiles requested=N cached=C sent=S resolved=R chunks=K failed=F err=…`
    func line(pane: String) -> String {
        "\(pane) profiles requested=\(requested) cached=\(cached) sent=\(sent) "
            + "resolved=\(resolved) chunks=\(chunks) failed=\(failed) err=\(error ?? "-")"
    }

    /// `true` when the server named everybody there was to name.
    var isComplete: Bool { failed == 0 && resolved == requested }
}

/// The one batched-profile loader. `@MainActor` like the view models that call it: the closure that
/// merges profiles runs on the main actor, between `await`s, never concurrently.
@MainActor
enum ProfileBatch {

    /// The largest id list one `POST /users/ids` may carry.
    ///
    /// The same number `APIClient.usersBatchSize` uses. `APIClient` chunks as well, so a caller that
    /// forgets to does not break; this loader chunks so that **one failed chunk cannot discard the
    /// others**, which is a property only the caller-side split can give.
    static let size = 100

    /// Distinct, non-empty ids in the caller's order — the only ids that may reach a request.
    static func clean(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func chunks(_ ids: [String]) -> [[String]] {
        guard size > 0, !ids.isEmpty else { return [] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

    /// Learn these authors: cache first, then `size` ids per request, one failed chunk at a time.
    ///
    /// - Parameters:
    ///   - ids: author ids from the rows on screen. Empty ids and duplicates are dropped here — a
    ///     system post's `""` is not a person and must never reach the request body.
    ///   - cache: profiles another screen already paid for. Read-only here: the object that made the
    ///     request is what remembers it (a `ChannelServing`/`SessionChannelService` does), so this
    ///     loader has exactly one job.
    ///   - fetch: one request for one chunk.
    ///   - onProfiles: called with every profile this load produced — cache hits first, then each
    ///     chunk that answered — so a caller can merge (and republish) incrementally rather than
    ///     waiting for the whole batch.
    static func load(_ ids: [String],
                     cache: UserProfileCache? = nil,
                     fetch: ([String]) async throws -> [MMUser],
                     onProfiles: ([MMUser]) -> Void = { _ in }) async -> ProfileBatchReport {
        var report = ProfileBatchReport()
        let wanted = clean(ids)
        report.requested = wanted.count
        guard !wanted.isEmpty else { return report }

        var known = Set<String>()
        if let cache {
            let cached = cache.known(ids: wanted)
            if !cached.isEmpty {
                onProfiles(cached)
                known.formUnion(cached.map(\.id))
            }
            report.cached = known.count
        }

        let outstanding = wanted.filter { !known.contains($0) }
        report.sent = outstanding.count
        for chunk in chunks(outstanding) {
            if Task.isCancelled { break }
            report.chunks += 1
            do {
                let answered = try await fetch(chunk)
                if !answered.isEmpty {
                    onProfiles(answered)
                    known.formUnion(answered.map(\.id))
                }
            } catch {
                // Not fatal: the rows this chunk would have named keep their fallback, the rows
                // another chunk named stay named, and the failure is a number in the report.
                report.failed += chunk.count
                if report.error == nil { report.error = Self.describe(error) }
            }
        }
        report.resolved = wanted.filter { known.contains($0) }.count
        return report
    }

    /// A diagnostics-safe one-liner for an error (never a credential; `MMError` is a status + path).
    static func describe(_ error: Error) -> String {
        if let mm = error as? MMError { return String(describing: mm) }
        return (error as NSError).localizedDescription
    }
}
