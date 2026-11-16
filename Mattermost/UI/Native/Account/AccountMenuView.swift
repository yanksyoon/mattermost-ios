// t_9dd73395 — the account menu: my status, my custom status, my profile, and sign out, in the
// top-right of the shell.
//
// Behaviour reference: mattermost/mattermost master @ `987e5712…` (webapp v12.0.1),
// `webapp/channels/src/components/user_account_menu/`:
//   * `user_account_menuButton.tsx` — the trigger: the profile picture with the presence dot, the
//     thing in the top-right corner, opening on click, `aria-haspopup='menu'`;
//   * `user_account_menu.tsx` — the items and their order (see `AccountMenuBuilder`);
//   * `user_account_out_of_office_menuitem.tsx` — the OOO item exists only while the status is OOO,
//     and its click **leaves** OOO (sets `online`), through the reset-status confirmation when the
//     auto-reset preference has not been answered;
//   * `user_account_dnd_menuitem.tsx` — the DND row is a sub-menu with five fixed end times plus a
//     date picker, and sends `dnd_end_time` in **seconds**;
//   * `user_account_custom_status_menuitem.tsx` / `user_account_set_custom_status_menuitem.tsx` —
//     one row whether or not a status is set; the set form shows it and offers to update it;
//   * `user_account_logout_menuitem.tsx` — log out.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// ## Where it lives, and why that is "the shell's top-right"
//
// The control is drawn in the channel pane's header row (`ChannelView.trailingControls`), beside the
// channel-info / pinned / Calls / Threads glyphs — i.e. the same corner upstream puts it in, in both
// the compact and the regular layout, because that header is the top-right of the workspace in both
// (`docs/t95-shell-tab-bar-decision.md`). It **replaces** T41's `nativeProfileButton` glyph: one
// identity surface, as upstream has one, and the profile is now reached through this menu's Profile
// row (`accountMenu.profile`) exactly as the web client reaches it through
// `UserAccountProfileMenuItem`. (The three live suites that used to tap `nativeProfileButton` now
// open the menu first — see T41ProfileUITests / T429ProfileTapUITests / TModalDismissUITests.)
//
// ## Sign out: this menu is the primary entry, Settings keeps its list
//
// `Settings ▸ Session ▸ Sign out of <server>` is **kept** (requirement 7's "decide and state"). It is
// a different surface for a different job: Settings lists *every* signed-in server, so a second
// server can be signed out without switching to it, and its row is what the T31 suite measures.
// Removing it would leave that path with no home. Both call the same `AuthCoordinator.signOut` and
// show the same confirmation copy, so there is one behaviour behind two doors, not two behaviours.
//
// ## Failure states (requirement 9)
//
// A write the server rejects leaves the model's previous status in place (`ProfileViewModel`\
// `.setPresence` / `.saveCustomStatus` roll back) and puts its sentence in `banner`. This view turns
// that into an alert — "Status not saved" + the model's own sentence — so the reader is told instead
// of watching a dot silently snap back. A failed *read* is different: the dot stays `unknown` (never
// "Online") and the menu still opens; its status rows simply carry no checkmark.
//
// Identifiers an XCUITest can rely on:
//   accountMenuButton                  the trigger (announced with its current status as the value)
//   accountMenu.name                   the avatar + display name row (opens my profile)
//   accountMenu.ooo                    the Out of office row (only while OOO)
//   accountMenu.setCustomStatus        "Set a custom status"
//   accountMenu.customStatus           the custom status that is set ("Update status")
//   accountMenu.status.<presence>      online / away / dnd / offline
//   accountMenu.dnd.<choice>           the DND sub-menu's end-time choices
//   accountMenu.dnd.custom             "Choose date and time"
//   accountMenu.profile                Profile
//   accountMenu.logout                 Sign out
//   accountMenu.leaveOOO.confirm       the confirmation's "Set status to …"
//   accountMenu.leaveOOO.cancel        the confirmation's "Stay …"
//   accountMenu.logoutConfirm          the sign-out confirmation's destructive button
//   accountMenu.failure                the alert's message (the model's own sentence)
//   customStatus.*                     the editor, unchanged from T41

import SwiftUI

/// The shell's account control: avatar + presence dot (+ custom-status emoji), opening the menu.
///
/// The coordinator owns the model (one per (server, user), warm across presentations), so the menu
/// and the profile sheet draw the **same** status memory, and a write from either is seen by both.
struct AccountMenuControl: View {
    let server: ServerConfig
    /// Opens my profile — the host's existing popover, so a profile opened from the menu is the same
    /// presentation (and the same sheet slot) as one opened from anywhere else.
    var onOpenProfile: (String) -> Void

    @EnvironmentObject private var profiles: ProfileCoordinator

    var body: some View {
        // The model is resolved here because it is `ObservableObject`: a value built in this body
        // could not be observed by a child, and `myModel(for:)` is cached, so building it on a redraw
        // costs nothing.
        if let model = profiles.myModel(for: server) {
            AccountMenuControlBody(model: model, server: server, onOpenProfile: onOpenProfile)
        }
    }
}

struct AccountMenuControlBody: View {
    @ObservedObject var model: ProfileViewModel
    let server: ServerConfig
    var onOpenProfile: (String) -> Void

    @EnvironmentObject private var auth: AuthCoordinator

    /// A status change that must be confirmed before it is written (leaving Out of office).
    private struct PendingStatusChange: Identifiable, Equatable {
        let new: UserPresence
        var id: String { new.rawValue }
    }

    @State private var pendingChange: PendingStatusChange?
    @State private var showsCustomStatusEditor = false
    @State private var showsSignOutConfirmation = false
    @State private var showsDNDCustomPicker = false
    @State private var dndCustomEnd = Date().addingTimeInterval(60 * 60)
    /// The last write's failure, shown as an alert. Set only for writes **this** view started: the
    /// custom-status editor draws the model's banner itself while it is up.
    @State private var failure: String?
    @State private var didLoad = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel("User's account menu")
        .accessibilityValue(model.presence.title)
        .accessibilityHint("Shows your status, custom status, profile and sign out")
        .accessibilityIdentifier("accountMenuButton")
        .task {
            // Once per control instance: a warm model re-reads only presence and the preference
            // (`ProfileViewModel.loadAccountMenu`), so this is two requests, not a screen reload.
            guard !didLoad else { return }
            didLoad = true
            await model.loadAccountMenu()
        }
        .sheet(isPresented: $showsCustomStatusEditor) {
            // Presented from the *menu*, not from inside a sheet, so a `NavigationStack` here is the
            // top-level presentation (not the nested sheet T40 measured). `CustomStatusEditorScreen`
            // is the T41 screen, unchanged — one editor for both entries.
            NavigationStack {
                CustomStatusEditorScreen(model: model)
            }
        }
        .sheet(isPresented: $showsDNDCustomPicker) {
            dndCustomPicker
        }
        .confirmationDialog(dialogTitle,
                            isPresented: Binding(get: { pendingChange != nil },
                                                 set: { if !$0 { pendingChange = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingChange) { change in
            Button(AccountMenuRules.confirmActionTitle(new: change.new),
                   role: .destructive) {
                pendingChange = nil
                perform { await model.setPresence(change.new, dndEndTimeSeconds: nil) }
            }
            .accessibilityIdentifier("accountMenu.leaveOOO.confirm")
            Button(AccountMenuRules.confirmCancelTitle(current: model.presence),
                   role: .cancel) {
                pendingChange = nil
            }
            .accessibilityIdentifier("accountMenu.leaveOOO.cancel")
        } message: { change in
            Text(AccountMenuRules.confirmMessage(current: model.presence, new: change.new))
        }
        .confirmationDialog("Sign out of \(server.name)?",
                            isPresented: $showsSignOutConfirmation,
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                // The same call Settings uses (`SettingsView.sessionSection`): local clear, the
                // webview cookie, then the best-effort revocation. The shell's phase change is what
                // lands on the sign-in screen.
                Task { await AccountMenuActions.signOut(server: server, auth: auth) }
            }
            .accessibilityIdentifier("accountMenu.logoutConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            // Settings' copy, verbatim: two doors, one sentence.
            Text("The session stored for this server on this device is cleared, and revoked on "
                 + "the server. You will need to sign in again. Messages on the server are not "
                 + "affected.")
        }
        .alert("Status not saved",
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
                .accessibilityIdentifier("accountMenu.failure")
        }
    }

    // MARK: - The trigger

    private var label: some View {
        ZStack(alignment: .bottomTrailing) {
            ProfileAvatarView(initials: initials,
                              hue: ProfileAvatarView.hue(for: model.userID),
                              image: model.avatar,
                              size: 28)
            PresenceDot(presence: model.presence, size: 10)
                .background(Circle().fill(Color(.systemBackground)))
                .offset(x: 2, y: 2)
        }
        .overlay(alignment: .topTrailing) {
            if let emoji = activeCustomStatus?.emoji, !emoji.isEmpty {
                customStatusBadge(emoji)
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }

    /// The custom-status badge: upstream adds a class to the button and draws the emoji at the
    /// picture's corner (`user_account_menu.scss` `.withCustomStatus`).
    private func customStatusBadge(_ emoji: String) -> some View {
        Text(SystemEmojiCatalogue.shared.character(for: emoji) ?? "💬")
            .font(.system(size: 11))
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color(.systemBackground)))
            .accessibilityHidden(true)
    }

    // MARK: - The menu

    @ViewBuilder
    private var menuContent: some View {
        ForEach(Array(model.accountMenuItems.enumerated()), id: \.offset) { index, item in
            if item.startsGroup && index > 0 { Divider() }
            menuItem(item)
        }
    }

    @ViewBuilder
    private func menuItem(_ item: AccountMenuItem) -> some View {
        switch item {
        case .name:
            Button {
                onOpenProfile(model.userID)
            } label: {
                // Avatar + name + "@username", as upstream's `UserAccountNameMenuItem` draws
                // (`getLabel`): the full name when there is one, the username otherwise.
                Label(model.profile?.displayName ?? "@\(model.profile?.username ?? "")",
                      systemImage: "person.crop.circle")
            }
            .accessibilityHint("Opens your profile")
            .accessibilityIdentifier("accountMenu.name")

        case .outOfOffice:
            Button {
                // Upstream's OOO row is the way *out* of OOO: its click sets `online` (through the
                // confirmation when the preference has not been answered).
                requestStatus(.online)
            } label: {
                Label("Out of office", systemImage: "checkmark")
            }
            .accessibilityValue("Automatic replies are enabled")
            .accessibilityIdentifier("accountMenu.ooo")

        case .setCustomStatus:
            Button {
                showsCustomStatusEditor = true
            } label: {
                Label("Set a custom status", systemImage: "face.smiling")
            }
            .accessibilityIdentifier("accountMenu.setCustomStatus")

        case .customStatus:
            Button {
                showsCustomStatusEditor = true
            } label: {
                Label(customStatusLabel, systemImage: "face.smiling")
            }
            .accessibilityHint("Update your custom status")
            .accessibilityIdentifier("accountMenu.customStatus")

        case .status(let presence):
            if presence == .dnd {
                dndMenu(checked: model.presence == .dnd)
            } else {
                Button {
                    requestStatus(presence)
                } label: {
                    Label(presence.title,
                          systemImage: model.presence == presence ? "checkmark" : presence.glyph)
                }
                .accessibilityAddTraits(model.presence == presence ? .isSelected : [])
                .accessibilityIdentifier("accountMenu.status.\(presence.rawValue)")
            }

        case .profile:
            Button {
                onOpenProfile(model.userID)
            } label: {
                Label("Profile", systemImage: "person.text.rectangle")
            }
            .accessibilityIdentifier("accountMenu.profile")

        case .logout:
            Button(role: .destructive) {
                showsSignOutConfirmation = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("accountMenu.logout")
        }
    }

    /// The DND row and its end-time sub-menu (upstream `UserAccountDndMenuItem`).
    @ViewBuilder
    private func dndMenu(checked: Bool) -> some View {
        Menu {
            ForEach(AccountMenuRules.DNDChoice.allCases) { choice in
                Button(choice.title) {
                    perform {
                        await model.setPresence(.dnd,
                                                dndEndTimeSeconds: choice.endTimeSeconds(from: Date()))
                    }
                }
                .accessibilityIdentifier(choice.identifier)
            }
            Divider()
            Button("Choose date and time") {
                dndCustomEnd = Date().addingTimeInterval(60 * 60)
                showsDNDCustomPicker = true
            }
            .accessibilityIdentifier(AccountMenuRules.DNDChoice.customIdentifier)
        } label: {
            Label("Do not disturb", systemImage: checked ? "checkmark" : "minus.circle.fill")
        }
        .accessibilityValue(dndSecondaryLabel)
        .accessibilityIdentifier("accountMenu.status.dnd")
    }

    private var dndCustomPicker: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Clears at",
                               selection: $dndCustomEnd,
                               in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("accountMenu.dnd.customDate")
                } footer: {
                    Text("Do not disturb ends at this time. The server enforces it, so every "
                         + "client sees the same end time.")
                }
            }
            .navigationTitle("Do not disturb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsDNDCustomPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        showsDNDCustomPicker = false
                        perform {
                            await model.setPresence(.dnd,
                                                    dndEndTimeSeconds: Int64(dndCustomEnd.timeIntervalSince1970.rounded()))
                        }
                    }
                    .accessibilityIdentifier("accountMenu.dnd.customSave")
                }
            }
        }
        .accessibilityIdentifier("accountMenu.dnd.customPicker")
    }

    // MARK: - Actions

    /// Ask (or not) and then write.
    ///
    /// The order is upstream's `shouldConfirmBeforeStatusChange` check at the *row*: leaving Out of
    /// office asks only while the auto-reset preference is unset. Every other status is written
    /// straight away, including while Out of office — which is the same flow upstream's status rows
    /// have (each one passes the same `shouldConfirmBeforeStatusChange`).
    private func requestStatus(_ presence: UserPresence) {
        guard presence != model.presence else { return }
        if model.shouldConfirmBeforeStatusChange {
            pendingChange = PendingStatusChange(new: presence)
            return
        }
        perform { await model.setPresence(presence, dndEndTimeSeconds: nil) }
    }

    /// Run a write and turn its failure into the alert. `banner` is consumed so the editor (which
    /// draws the same value) cannot show a sentence this view already showed.
    private func perform(_ action: @escaping () async -> Void) {
        Task {
            await action()
            if let banner = model.banner {
                failure = banner
                model.consumeBanner()
            }
        }
    }

    // MARK: - Derived copy

    private var initials: String {
        guard let profile = model.profile else { return "" }
        return profile.initials
    }

    /// The custom status this control draws, already filtered by the expiry rule (`isCustomStatusSet`).
    private var activeCustomStatus: UserCustomStatus? {
        guard model.isCustomStatusSet else { return nil }
        return model.profile?.customStatus
    }

    /// The row's label for a set custom status: emoji + text when both exist, whichever one exists
    /// otherwise, and "Update status" when the status carries an expiry but no text (upstream's three
    /// label shapes, `user_account_set_custom_status_menuitem.tsx`).
    private var customStatusLabel: String {
        guard let status = activeCustomStatus else { return "Update status" }
        let glyph = status.emoji.isEmpty
            ? ""
            : (SystemEmojiCatalogue.shared.character(for: status.emoji) ?? ":\(status.emoji):")
        switch (glyph.isEmpty, status.text.isEmpty) {
        case (false, false): return "\(glyph) \(status.text)"
        case (false, true):
            if let expires = status.expiresAt {
                return "\(glyph) Until \(Self.shortTime(expires))"
            }
            return glyph
        case (true, false): return status.text
        case (true, true): return "Update status"
        }
    }

    private var dialogTitle: String {
        AccountMenuRules.confirmTitle(current: model.presence)
    }

    private var dndSecondaryLabel: String {
        guard model.presence == .dnd else { return "Disables all notifications" }
        return AccountMenuRules.dndSecondaryLabel(endTime: model.status?.dndEndTime, now: Date())
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
