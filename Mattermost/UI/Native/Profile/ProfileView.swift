// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/user_profile/user_profile.tsx (the sheet's layout: avatar, name, username,
//        custom status, role badges, the option rows), app/screens/user_profile/options/ (send
//        message, view profile), app/components/profile_picture/ (the initials fallback),
//        app/components/custom_status/custom_status.tsx (the emoji + text pill),
//        app/components/user_status/ (the presence dot).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// ## Presentation
//
// One sheet, and **nothing presented from inside it except a push**. The status setter and the custom
// status editor are `navigationDestination` pushes on this stack, not sheets: T40's validator measured
// a nested sheet whose confirmation action never ran (`AddMembersView`'s submit — zero requests on the
// wire), and a status setter that looks responsive but sends nothing is exactly the failure this
// surface cannot afford. A push has no second presentation to lose.
//
// Identifiers an XCUITest can rely on (also listed in docs/t41-build-note.md §4):
//   profileSheet            the sheet
//   profile.done            close
//   profile.name            the display name
//   profile.username        `@username`
//   profile.presence        the presence row (its label carries "Online"/"Away"/…)
//   profile.customStatus    the custom status pill's text (absent when there is none)
//   profile.roles           the role badges, one label
//   profile.localTime       the local-time line
//   profile.lastActive      the last-active line
//   profile.joined          "Joined …"
//   profile.position        the job title / bio line
//   profile.message         "Send message" (absent when it cannot work)
//   profile.messageReason   why it cannot work
//   profile.setStatus       opens the status setter (my own profile only)
//   profile.customStatusRow opens the custom status editor (my own profile only)
//   profile.clearStatus     clears the custom status (my own profile only, when one is set)
//   profile.banner          a write failure
//   profile.error / profile.retry   the load failure and its retry

import SwiftUI
import UIKit

/// Which account a host wants the profile sheet for. A one-field item so `.sheet(item:)` can key on
/// it (a `String` cannot be an `Identifiable` item without a wrapper).
struct ProfileTarget: Identifiable, Equatable {
    let userID: String
    var id: String { userID }
}

/// The one profile a pane can have open, as a single-slot state machine.
///
/// `ProfileTarget` is a value; this is the pane's *presentation* of it: exactly one account at a
/// time, a second tap re-aims the sheet instead of stacking another presentation, and only a
/// dismissal empties the slot. Pairing it with `.sheet(item:)` is what makes "only one popover is
/// open" structural rather than a rule each host has to remember (`t_42968927`).
struct ProfilePopoverState: Equatable {
    /// The account whose profile is open. `.sheet(item:)` writes `nil` here on dismissal, so it is
    /// the sheet's binding, not a private cache.
    var target: ProfileTarget?

    var isPresenting: Bool { target != nil }

    /// Open (or re-aim) this pane's one profile sheet.
    mutating func present(userID: String) { target = ProfileTarget(userID: userID) }
}

/// The sheet the shell presents for one account.
struct ProfileSheet: View {
    let server: ServerConfig
    let userID: String
    /// The app's navigation model, so "Send message" can open the conversation it just created.
    /// `nil` in a preview or a host that only draws the sheet.
    var navigation: NativeNavigation?

    @EnvironmentObject private var coordinator: ProfileCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProfileViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ProfileScreen(model: model,
                                  server: server,
                                  onClose: { dismiss() },
                                  onOpenConversation: { channel in
                                      openConversation(channel)
                                  })
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("profile.loading")
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("profile.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            let resolved = coordinator.model(for: server, userID: userID)
            model = resolved
            // One presence read on open, warm model or not (`load()`): the sheet may have been
            // closed for minutes, and this server never sends a colleague's `status_change`.
            await resolved.load()
            // Presence keeps itself current while the profile is open. `status_change` cannot do it
            // for somebody else — the server addresses that frame to the account that changed — so the
            // batched read is polled, which is what the web client does too (see
            // `ProfileViewModel.runPresenceUpdates`). This task is cancelled when the sheet closes.
            await resolved.runPresenceUpdates(interval: coordinator.presenceInterval)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileSheet")
    }

    /// Open the conversation the server answered, then close the sheet.
    private func openConversation(_ channel: MMChannel) {
        guard let navigation else {
            dismiss()
            return
        }
        var request = NativeChannelRequest(serverID: server.id, channelID: channel.id)
        request.teamID = channel.teamId.isEmpty ? nil : channel.teamId
        request.channelName = channel.name.isEmpty ? nil : channel.name
        _ = navigation.openChannel(request)
        dismiss()
    }
}

/// The profile screen itself (the sheet's root; also usable pushed, e.g. from a member list).
struct ProfileScreen: View {
    @ObservedObject var model: ProfileViewModel
    let server: ServerConfig
    let onClose: () -> Void
    var onOpenConversation: (MMChannel) -> Void = { _ in }

    @EnvironmentObject private var coordinator: ProfileCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showsStatusSetter = false
    @State private var showsCustomStatusEditor = false

    private var now: Date { Date() }

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                if model.profile == nil {
                    ProgressView("Reading this profile…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("profile.loading")
                } else {
                    content
                }
            case .failed(let message):
                failureState(message)
            case .loaded:
                content
            }
        }
        .navigationDestination(isPresented: $showsStatusSetter) {
            StatusSetterScreen(model: model, dndChoices: StatusDuration.dndChoices)
        }
        .navigationDestination(isPresented: $showsCustomStatusEditor) {
            CustomStatusEditorScreen(model: model)
        }
        .onChange(of: model.conversation) { _, channel in
            guard let channel else { return }
            model.consumeConversation()
            onOpenConversation(channel)
        }
    }

    // MARK: Sections

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let banner = model.banner {
                    bannerView(banner)
                }
                header
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            ProfileInfoRow(row: row)
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                actions
            }
            .padding(16)
        }
        .refreshable { await model.load(force: true) }
    }

    /// The avatar, name, username, presence and custom status.
    private var header: some View {
        VStack(spacing: 10) {
            ProfileAvatarView(initials: model.profile?.initials ?? "",
                              hue: ProfileAvatarView.hue(for: model.userID),
                              image: model.avatar,
                              size: 88)
            VStack(spacing: 2) {
                Text(model.profile?.displayName ?? "")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("profile.name")
                if let username = model.profile?.username, !username.isEmpty {
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile.username")
                }
            }
            presenceRow
            if let status = model.activeCustomStatus,
               let text = ProfileDateFormat.customStatusText(status, now: now) {
                CustomStatusPill(emoji: status.emoji, text: text)
                    .accessibilityIdentifier("profile.customStatus")
            }
            if !roleBadges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(roleBadges, id: \.self) { label in
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("profile.roles")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var presenceRow: some View {
        HStack(spacing: 6) {
            PresenceDot(presence: model.presence)
            Text(presenceText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("profile.presence")
        }
    }

    /// "Online" / "Away" / "Do not disturb until 4:15 PM" / "Offline" / "Status unknown".
    ///
    /// A do-not-disturb end time is drawn when the server sent one, because "do not disturb" with no
    /// end reads like a permanent choice and usually is not.
    private var presenceText: String {
        if let sentence = ProfileDateFormat.dndSentence(model.status, now: now) {
            return sentence
        }
        return model.presence.title
    }

    /// The badges, as strings so `ForEach` has a stable identity.
    private var roleBadges: [String] {
        guard let profile = model.profile else { return [] }
        return profile.roleLabels.map(\.title)
    }

    /// The fact rows, each omitted when the server sent nothing: an empty row is worse than no row.
    private var rows: [ProfileInfoRow.Model] {
        guard let profile = model.profile else { return [] }
        var rows: [ProfileInfoRow.Model] = []
        if !profile.position.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(.init(id: "position", title: "Position", value: profile.position,
                              identifier: "profile.position"))
        }
        if !profile.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append(.init(id: "nickname", title: "Nickname", value: profile.nickname,
                              identifier: "profile.nickname"))
        }
        if !profile.email.isEmpty, model.isMe || !profile.isSSOAccount {
            rows.append(.init(id: "email", title: "Email", value: profile.email,
                              identifier: "profile.email"))
        }
        rows.append(.init(id: "localTime",
                          title: "Local time",
                          value: ProfileDateFormat.localTimeSentence(zoneID: profile.localTimeZoneID,
                                                                     at: now),
                          identifier: "profile.localTime"))
        rows.append(.init(id: "lastActive",
                          title: "Activity",
                          value: ProfileDateFormat.lastActive(presence: model.presence,
                                                              lastActivity: profile.lastActivityDate,
                                                              now: now),
                          identifier: "profile.lastActive"))
        if let joined = ProfileDateFormat.joined(ms: profile.createAt) {
            rows.append(.init(id: "joined", title: "Member", value: joined,
                              identifier: "profile.joined"))
        }
        return rows
    }

    @ViewBuilder
    private var actions: some View {
        // Rows come from `ProfileActionSet` (permission-gated, unit-tested), not from conditions
        // repeated here: the sheet draws exactly what the model says this viewer may do.
        VStack(spacing: 10) {
            if model.actions.offers(.message) {
                Button {
                    Task { await model.openConversation() }
                } label: {
                    Label("Send message", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWriting)
                .accessibilityIdentifier("profile.message")
            } else if let reason = model.actions.messageUnavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("profile.messageReason")
            }
            if let failure = model.conversationFailure {
                bannerView(failure)
            }
            if model.actions.offers(.setStatus) {
                Button {
                    showsStatusSetter = true
                } label: {
                    Label("Set a status", systemImage: "circle.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("profile.setStatus")

                Button {
                    showsCustomStatusEditor = true
                } label: {
                    Label(model.activeCustomStatus == nil ? "Set a custom status" : "Edit custom status",
                          systemImage: "face.smiling")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("profile.customStatusRow")

                if model.actions.offers(.clearCustomStatus) {
                    Button(role: .destructive) {
                        Task { await model.clearCustomStatus() }
                    } label: {
                        Label("Clear custom status", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWriting)
                    .accessibilityIdentifier("profile.clearStatus")
                }
            }
        }
    }

    private func bannerView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.consumeBanner()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.banner")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("profile.error")
            Button("Try again") {
                Task { await model.load(force: true) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("profile.retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// One label/value row of the profile's fact list.
struct ProfileInfoRow: View {
    struct Model: Identifiable, Equatable {
        let id: String
        let title: String
        let value: String
        let identifier: String
    }

    let row: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.value)
                .font(.subheadline)
                .accessibilityIdentifier(row.identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The presence dot, in the four tones the server can report plus "unknown".
///
/// `unknown` is drawn hollow-neutral and never as "offline": the difference matters when a status read
/// failed, and T40's member list makes the same choice for the same reason.
struct PresenceDot: View {
    let presence: UserPresence
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle().strokeBorder(Color(.systemBackground), lineWidth: 1)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch presence {
        case .online: return .green
        case .away: return .yellow
        case .dnd: return .red
        case .offline: return Color.secondary.opacity(0.55)
        case .unknown: return Color.secondary.opacity(0.3)
        }
    }
}

/// The avatar: the server's picture when there is one, initials otherwise.
struct ProfileAvatarView: View {
    let initials: String
    let hue: Double
    var image: Data? = nil
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            if let image, let uiImage = UIImage(data: image) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color(hue: hue, saturation: 0.45, brightness: 0.82))
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityIdentifier("profile.avatar")
        .accessibilityLabel("Profile picture")
    }

    /// A stable colour per account, so the same person is the same colour on every screen and in every
    /// run. (A random colour would make a screenshot diff look like a data change.)
    static func hue(for userID: String) -> Double {
        var hash: UInt64 = 5381
        for byte in userID.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Double(hash % 360) / 360
    }
}

/// The custom status pill: the emoji's glyph and the text beside it.
struct CustomStatusPill: View {
    let emoji: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            if let glyph = SystemEmojiCatalogue.shared.character(for: emoji) {
                Text(glyph).font(.subheadline)
            } else if !emoji.isEmpty {
                // A name this build's system table does not know (a server custom emoji): drawn as its
                // name rather than as nothing, so the row is never mysteriously blank.
                Text(":\(emoji):").font(.caption)
            }
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemBackground), in: Capsule())
    }
}
