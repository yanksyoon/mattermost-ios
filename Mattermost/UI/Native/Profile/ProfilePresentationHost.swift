// T5449 (C2 of `t_8f9f5449`) — where a profile may legally present, decided once per host.
//
// Spec of record: `docs/t_8f9f5449-profile-popover-parity.md` §2.2 (presentation legality) and §2.3
// (the per-host table).
//
// **The rule is a measurement, not a preference.** A profile opened from *inside a modal is pushed, not
// presented*: T40's validator measured a nested sheet whose confirmation action never ran
// (`AddMembersView`'s submit — zero requests on the wire), and `ProfileView.swift`'s own header states
// the same rule for this surface ("One sheet, and nothing presented from inside it except a push").
//
// The hosts are not at the same level of the presentation stack, so the *same view* has two legal
// presentations depending on who hosts it:
//
//   host                                        container                          legal presentation
//   ChannelPaneContent                          a pane destination                  sheet (T41/T429, shipped)
//   ThreadPostListView                          a pane destination                  sheet, in its one sheet slot
//   Search / Saved / Mentions, compact layout   a `TabView` tab (no stack above)    sheet, own slot
//   the same three, regular layout              `NativeShellView`'s `lookupSheet`   push on that stack
//                                               → `NavigationStack`
//   `PostCollectionView` in `PinnedPostsView`   a sheet with its own stack          push on that stack
//
// The answer therefore belongs to the **container**, not to the pane: `NativeShellView` sets
// `.environment(\.profilePresentation, .push)` on the three lookup-sheet contents (regular layout only —
// the compact tabs keep the default) and `PinnedPostsView` sets it on its own content. Every other host
// leaves the default, `.sheet`, which is exactly the T41/T429 presentation T39/T41/T42 already assert.
//
// `ProfilePresentationHost` is the **one** helper a host calls: it reads the environment and attaches
// either `.sheet(item:)` → `ProfileSheet` or `.navigationDestination(item:)` → `PushedProfileScreen`, so
// a host cannot pick the wrong one by hand, and no host adds a second `.sheet` modifier to a view tree
// that already has one (spec finding F2: the channel pane's four `.sheet` modifiers on one view are the
// recorded shape that silently drops presentations).
//
// Identifiers an XCUITest can rely on:
//   profileSheet   the *sheet* form (`ProfileSheet`, unchanged from T41/T429) — it must be **absent**
//                  when the profile arrived as a push
//   profilePush    the *pushed* form (this file); `profile.username` and the rest of `ProfileScreen`'s
//                  identifiers are the same in both forms, because both draw the same screen

import SwiftUI

/// How a host may present a profile.
///
/// Slotted into the environment by the container that knows the presentation stack the host sits in
/// (`NativeShellView`'s lookup sheet, `PinnedPostsView`'s own `NavigationStack`). Every host that does
/// not set it gets `.sheet`: the presentation T41 shipped and T41/T429's live suites assert.
enum ProfilePresentation: Equatable, Sendable {
    /// `.sheet(item:)` — a host at the root of a presentation (a tab, a pane destination).
    case sheet
    /// `.navigationDestination(item:)` — a host already inside a presentation, on that stack.
    case push
}

private struct ProfilePresentationKey: EnvironmentKey {
    static let defaultValue: ProfilePresentation = .sheet
}

extension EnvironmentValues {
    /// How this host presents a profile. Default `.sheet` (see `ProfilePresentation`).
    var profilePresentation: ProfilePresentation {
        get { self[ProfilePresentationKey.self] }
        set { self[ProfilePresentationKey.self] = newValue }
    }
}

/// The one attach point: a host hands its `ProfilePopoverState` here and gets whichever presentation
/// its container declared legal.
///
/// Usage from a host (see `SearchView`, `PostCollectionView`, `ActivityFeedView`):
///
/// ```swift
/// .profilePresentationHost($profilePopover, server: server, navigation: navigation)
/// ```
///
/// The binding is `ProfilePopoverState.target`, so the presentation's own dismissal (swiping the sheet,
/// tapping Back on the push) empties the one-slot machine — a second tap re-aims it instead of stacking
/// a second presentation.
struct ProfilePresentationHost: ViewModifier {
    @Binding var state: ProfilePopoverState
    let server: ServerConfig
    /// The app's navigation model, so a profile's "Send message" can open the conversation it creates.
    var navigation: NativeNavigation?

    @Environment(\.profilePresentation) private var presentation

    @ViewBuilder
    func body(content: Content) -> some View {
        switch presentation {
        case .sheet:
            content.sheet(item: target) { target in
                ProfileSheet(server: server, userID: target.userID, navigation: navigation)
            }
        case .push:
            // iOS 17 floor (`IPHONEOS_DEPLOYMENT_TARGET = 17.0`): `navigationDestination(item:)` is the
            // item-bound form, so the destination cannot outlive (or contradict) the state. It is only
            // legal *inside* a `NavigationStack` — both push hosts above attach it to content that is
            // already inside one.
            content.navigationDestination(item: target) { target in
                PushedProfileScreen(server: server, target: target, navigation: navigation)
            }
        }
    }

    /// One binding, two presentations: both write `nil` back into the same slot on dismissal.
    private var target: Binding<ProfileTarget?> {
        Binding(get: { state.target }, set: { state.target = $0 })
    }
}

extension View {
    /// Attach this host's legal profile presentation (sheet or push — see `ProfilePresentation`).
    func profilePresentationHost(_ state: Binding<ProfilePopoverState>,
                                 server: ServerConfig,
                                 navigation: NativeNavigation? = nil) -> some View {
        modifier(ProfilePresentationHost(state: state, server: server, navigation: navigation))
    }
}

/// A profile **pushed** onto a stack that already carries a presentation (spec §2.2).
///
/// It is the same `ProfileScreen` the sheet draws — same identifiers (`profile.username`, …), same
/// presence polling, same actions — behind the stack's back button instead of a sheet's Done button.
/// The model is resolved through `ProfileCoordinator` in `.task`, exactly as `ProfileSheet` does, so a
/// push and a sheet for the same account share one warm model (and one socket subscription), and the
/// write rows' context is prepared by the **same** `prepareActions` call the sheet makes (t_dc0ea74d:
/// without it `actionContext` stayed `unknown` and both C3 rows were silently absent here).
///
/// What it deliberately does **not** carry: `profileSheet`. A test that asserts a profile arrived as a
/// push asserts `profileSheet` is absent and `profilePush` is present — the two forms cannot both be on
/// screen, and nothing here presents a second modal from inside the first one.
struct PushedProfileScreen: View {
    let server: ServerConfig
    let target: ProfileTarget
    /// The app's navigation model, so "Send message" can open the conversation it just created.
    var navigation: NativeNavigation?

    @EnvironmentObject private var coordinator: ProfileCoordinator
    /// The two write rows' environment (t_dc0ea74d). The sheet reads the same two; a push that did
    /// not would offer a Call row whose tap could not join anything, or an Add row with no team.
    @EnvironmentObject private var calls: CallsCoordinator
    @EnvironmentObject private var resolver: SurfaceModeResolver
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProfileViewModel?

    var body: some View {
        Group {
            if let model {
                ProfileScreen(model: model,
                              server: server,
                              onClose: { dismiss() },
                              onOpenConversation: { channel, intent in
                                  openConversation(channel, intent: intent)
                              },
                              // The picker's team is the shell's, exactly as the sheet's is: the Add
                              // row is team-scoped, and `ProfileScreen` renders nothing when this is
                              // nil (a dead row would be worse than an absent one).
                              teamID: navigation?.location.teamID)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("profile.loading")
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        // The stack's own back button is the dismissal — nothing is presented from inside a push, which
        // is the whole reason this form exists (T40's nested-sheet measurement).
        .task {
            let resolved = Self.resolveModel(target: target, server: server, coordinator: coordinator)
            model = resolved
            await resolved.load()
            // The two write rows' gate — **the sheet's own call, same arguments** (t_dc0ea74d). C3
            // left this out of the push and the pushed form drew neither row: an unresolved context
            // offers nothing, by the matrix's "unknown is absent" rule.
            await coordinator.prepareActions(model: resolved,
                                             server: server,
                                             teamID: navigation?.location.teamID,
                                             callsAvailable: calls.isCallsAvailable(serverID: server.id),
                                             callsSurfaceNative: resolver.resolvedMode(for: .calls) == .native,
                                             hasLiveCallElsewhere: calls.hasLiveCall)
            // Presence keeps itself current while the profile is open; the task is cancelled when the
            // push pops. Same calls as `ProfileSheet.task`, on purpose.
            await resolved.runPresenceUpdates(interval: coordinator.presenceInterval)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profilePush")
    }

    /// The model this push draws.
    ///
    /// Separated from `body` so the unit target can pin the target → model mapping with no server
    /// (the coordinator's `ProfileServing` is injected): the push must resolve **the target's** account
    /// through the same per-(server, user) cache the sheet uses, so re-aiming at the same account reuses
    /// the warm model instead of reading the profile twice.
    @MainActor
    static func resolveModel(target: ProfileTarget,
                             server: ServerConfig,
                             coordinator: ProfileCoordinator) -> ProfileViewModel {
        coordinator.model(for: server, userID: target.userID)
    }

    /// Open the conversation the server answered, then pop back to the list the reader came from.
    ///
    /// The same route `ProfileSheet.openConversation` performs, and now with the same intent rule: for
    /// `.call` the pane is asked to join the call **after** this push is popped and the DM is the
    /// shell's location (`CallsJoinEntry` owns `CallsSurfaceView`; a full-screen cover raised while a
    /// presentation is still up is T40's measured nested-presentation failure). Nothing here presents
    /// the call surface. It is repeated rather than shared because the two dismissals differ (a sheet
    /// dismisses itself, a push pops) and `ProfileView.swift` is C3's file in this same programme.
    ///
    /// The body is `route` — a static seam, so the ordering below is run by the unit target
    /// (`T5449ProfilePresentationTests`, t_10d3db63) instead of only being readable here.
    private func openConversation(_ channel: MMChannel, intent: ProfileConversationIntent) {
        Self.route(channel,
                   intent: intent,
                   serverID: server.id,
                   dismiss: { dismiss() },
                   open: navigation.map { navigation in { _ = navigation.openChannel($0) } },
                   requestStart: { calls.requestStart(serverID: $0, channelID: $1) })
    }

    /// The conversation route, separated from the view so the unit target can pin the **order** with
    /// no UI, no panel and no audio (t_10d3db63 — the tap path `1d67294` added was code-reading only).
    ///
    /// The order is the contract, and each step is the precondition of the next:
    ///   1. **pop first.** `CallsJoinEntry` presents `CallsSurfaceView` from the pane; a presentation
    ///      raised while another one is still up is T40's measured failure (a confirmation that never
    ///      ran, zero requests on the wire), and a push that stayed on screen would keep the DM's pane
    ///      from being the shell's location.
    ///   2. **then hand the DM to the pane.** `openChannel` is what makes the DM the shell's location,
    ///      so it is what makes a `CallsJoinEntry` for the DM exist at all.
    ///   3. **then, only for `.call`, ask the pane to join.** `CallsCoordinator.requestStart` is a
    ///      one-shot intent, consumed by `consumeStart` only for the channel it names — so it must be
    ///      requested against the DM the pane is now showing, not before the route lands.
    ///
    /// `open` is `nil` when the push has no `NativeNavigation` (a preview, or a host that only draws
    /// the screen): with no pane to route to, the only honest action is the pop.
    ///
    /// Why a seam and not a live XCUITest: pressing Call starts a real calls session, and T44d §4.2
    /// records the measured `AURemoteIO::Initialize` abort under host load — the hazard that keeps the
    /// live suite's own Call press alone on a quiet host, and the reason the pushed-form live test
    /// asserts the row instead of pressing it. This runs the ordering in the unit leg on every CI run;
    /// the sheet's live test keeps the server-side oracle (`GET …/calls/{id}/active`).
    @MainActor
    static func route(_ channel: MMChannel,
                      intent: ProfileConversationIntent,
                      serverID: UUID,
                      dismiss: () -> Void,
                      open: ((NativeChannelRequest) -> Void)?,
                      requestStart: (UUID, String) -> Void) {
        guard let open else {
            dismiss()
            return
        }
        var request = NativeChannelRequest(serverID: serverID, channelID: channel.id)
        request.teamID = channel.teamId.isEmpty ? nil : channel.teamId
        request.channelName = channel.name.isEmpty ? nil : channel.name
        dismiss()
        open(request)
        if intent == .call {
            requestStart(serverID, channel.id)
        }
    }
}
