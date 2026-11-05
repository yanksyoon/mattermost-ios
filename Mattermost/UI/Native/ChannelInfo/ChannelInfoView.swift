// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_info/index.ts (the screen assembly), channel_info.tsx (the layout: title,
//        member count, purpose/header, the option rows), options/index.tsx + options/members/*
//        (the member count row), destructive_options/index.tsx (leave, archive),
//        app/components/channel_actions/leave_channel_label (the confirmation),
//        app/components/channel_info_attributes (purpose/header blocks), extra/extra.tsx (the
//        "Add members" row), title/* (the header).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// Scope: the card names the channel-info surface, the member list, add/remove, leave, channel settings,
// archive/unarchive. Rows Mattermost also draws here — notifications, files, pinned, bookmarks, shared
// channels, convert-to-private — are **not** in this card and are deliberately absent rather than drawn
// as buttons that do nothing.
//
// The surface switch: `Surface.channelInfo` is **native by default** since `t_05caa678` (T55-AV-R
// passed it; T40 shipped the screen but never appended it to the approval registry). Two entries
// reach this sheet from the pane, and only one of them is gated:
//   * the pane's title — the whole label is the control, **not** gated, because `.channelView` is
//     pane-owning and there is no web client behind it to answer the tap (a gate there was the
//     reported defect: channel details unreachable on a default build);
//   * the `info.circle` glyph in the trailing controls — gated on `.channelInfo` resolving native.
// Bookmarks are not drawn here: upstream puts the bar under the channel header
// (`app/screens/channel/header/bookmarks.tsx`), and this repo's bar lives in
// `ChannelBookmarks.swift` for the same reason — one place, not two.

import SwiftUI

/// The one sheet `ChannelInfoView` presents, as an identity rather than two booleans.
///
/// Two state flags meant two `.sheet` modifiers on one view, and a sheet added later would have been
/// a third — the shape that drops presentations silently (and that `t_ddf85143` is about).
fileprivate enum ChannelInfoSheetRoute: Identifiable {
    case pinned
    case addMembers

    var id: String {
        switch self {
        case .pinned: return "pinned"
        case .addMembers: return "addMembers"
        }
    }
}

/// The sheet the channel header presents: a navigation stack whose root is the info screen.
struct ChannelInfoSheet: View {
    let server: ServerConfig
    let channelID: String
    /// The team the channel belongs to when the caller already knows it. It may be empty — a channel
    /// pane opened from a deep link knows only the channel — and the model then repairs it from the
    /// channel itself (measured: `MMChannel.teamId` is always set for a team channel, and empty for a DM).
    var teamID: String = ""
    /// The pane's title, used for a DM/GM (their `display_name` is empty on the server).
    let fallbackTitle: String?
    /// T52: the channel pane's navigation model, image store and download coordinator. The pinned row
    /// needs the first (it opens T38/T39's own sheet), and the files list hands the last two to T38's
    /// preview so a file opened from here is the same preview a post attachment opens.
    var navigation: NativeNavigation? = nil
    var imageStore: ChannelImageStore? = nil
    var downloads: AttachmentDownloads? = nil

    @EnvironmentObject private var coordinator: ChannelInfoCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChannelInfoViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ChannelInfoView(model: model,
                                    server: server,
                                    navigation: navigation,
                                    imageStore: imageStore,
                                    downloads: downloads,
                                    onClose: { dismiss() })
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Channel info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("channelInfo.done")
                }
            }
        }
        .task {
            let resolved = coordinator.model(for: server,
                                             channelID: channelID,
                                             teamID: teamID,
                                             title: fallbackTitle)
            model = resolved
            await resolved.load()
        }
        // The leave hand-off lives in `ChannelInfoView`, which observes the model: this sheet holds it as
        // a plain `@State`, so a published change does not re-run this body (measured — the sheet stayed
        // open after a successful leave when the `.onChange` was here).
        .accessibilityIdentifier("channelInfo.sheet")
    }
}

/// The channel-info screen: what this channel is, who is in it, and what I may do to it.
struct ChannelInfoView: View {
    @ObservedObject var model: ChannelInfoViewModel
    let server: ServerConfig
    /// T52: needed by the pinned row (it opens the existing pinned sheet, which navigates) and by the
    /// files list (T38's preview). Optional so a preview host that has no navigation still draws the
    /// screen — the pinned row is then simply not drawn.
    var navigation: NativeNavigation? = nil
    var imageStore: ChannelImageStore? = nil
    var downloads: AttachmentDownloads? = nil
    let onClose: () -> Void

    @EnvironmentObject private var coordinator: ChannelInfoCoordinator
    @State private var confirmLeave = false
    @State private var confirmArchive = false
    @State private var confirmUnarchive = false
    @State private var showsMembers = false
    @State private var showsSettings = false
    @State private var showsNotifications = false
    @State private var showsFiles = false
    /// t_d088f075: the conversion screen, pushed from its row; the model is built from the tap so a
    /// reopened screen never shows a previous attempt's name.
    @State private var showsConvert = false
    @State private var conversionModel: ConvertGMToChannelViewModel?
    /// Built from the row's own tap, so the pushed screen always has its model (T52-R3).
    @State private var filesModel: ChannelFilesViewModel?
    /// The **one** sheet this screen presents, and the item that closes it.
    ///
    /// This screen used to carry two `.sheet(isPresented:)` modifiers (`showsPinned`,
    /// `showsAddMembers`) on the same view. That is the shape T40 measured dropping a presentation —
    /// no error, no sheet, the tap just does nothing — and the shape `t_ddf85143` names as the
    /// systemic modal defect. One item-bound slot instead: whichever row was tapped is the item, and
    /// each sheet's own close clears that same item, so there is one state and one dismissal rule.
    @State private var sheet: ChannelInfoSheetRoute? = nil

    var body: some View {
        List {
            switch model.phase {
            case .idle, .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            case .failed(let message):
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("channelInfo.loadError")
                    Button("Try again") { Task { await model.load() } }
                }
            case .ready:
                headerSection
                if let note = model.readOnlyNote {
                    Section {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("channelInfo.readOnlyNote")
                    }
                }
                ignoreMentionsSection
                actionsSection
                sharedTeamsSection
                if let banner = model.banner {
                    Section {
                        Text(banner)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("channelInfo.banner")
                    }
                }
                if let refused = model.refusedMessage {
                    Section {
                        Text(refused)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("channelInfo.refused")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load() }
        .navigationTitle("Channel info")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsMembers) {
            ChannelMembersView(model: model, canManage: model.capabilities.canManageMembers)
        }
        .navigationDestination(isPresented: $showsSettings) {
            ChannelSettingsView(model: model)
        }
        // T52: the notification-preference screen and the channel's files are pushes inside the same
        // navigation stack the sheet already owns — the reader keeps the info screen's Back.
        .navigationDestination(isPresented: $showsNotifications) {
            ChannelNotificationsView(model: model)
        }
        .navigationDestination(isPresented: $showsFiles) {
            if let filesModel {
                ChannelFilesView(files: filesModel,
                                 channelID: model.channelID,
                                 imageStore: imageStore,
                                 downloads: downloads)
            }
        }
        // t_d088f075: the group-message conversion. On success the sheet closes and the reader lands on
        // the converted channel through `NativeNavigation` — the one funnel every other "go to a
        // channel" path uses, so a phone push and a split-view selection agree. The **id is unchanged**
        // by the conversion (measured), so this re-selects the conversation already open.
        .navigationDestination(isPresented: $showsConvert) {
            if let conversionModel {
                ConvertGMToChannelView(model: conversionModel) { target in
                    onClose()
                    // The channel's record changed (a group message became a private channel with the
                    // same id): tell the open pane so its header refetches, then land on it. Order
                    // matters only in that both happen from this one completion.
                    navigation?.channelDidChange(serverID: server.id, channelID: target.channelID)
                    navigation?.openChannel(NativeChannelRequest(serverID: server.id,
                                                                 teamID: target.teamID,
                                                                 channelID: target.channelID,
                                                                 channelName: target.channelName))
                }
            }
        }
        // T52: the pinned row opens T39's existing sheet, not a second pinned list. One item-bound
        // slot for this screen (see `sheet`): the add-people picker is the other item.
        .sheet(item: $sheet) { route in
            switch route {
            case .pinned:
                if let navigation {
                    PinnedPostsView(server: server,
                                    channelID: model.channelID,
                                    channelName: model.channel?.name,
                                    navigation: navigation,
                                    onClose: { sheet = nil })
                }
            case .addMembers:
                AddMembersView(model: model, server: server)
            }
        }
        .confirmationDialog(leavePrompt.title,
                            isPresented: $confirmLeave,
                            titleVisibility: .visible) {
            Button(leavePrompt.confirmTitle, role: .destructive) {
                Task { await model.leave() }
            }
            .accessibilityIdentifier("channelInfo.leave.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(leavePrompt.message)
        }
        .confirmationDialog(archivePrompt.title,
                            isPresented: $confirmArchive,
                            titleVisibility: .visible) {
            Button("Archive", role: .destructive) { Task { await model.archive() } }
                .accessibilityIdentifier("channelInfo.archive.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(archivePrompt.message)
        }
        .confirmationDialog(unarchivePrompt.title,
                            isPresented: $confirmUnarchive,
                            titleVisibility: .visible) {
            Button("Unarchive") { Task { await model.unarchive() } }
                .accessibilityIdentifier("channelInfo.unarchive.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unarchivePrompt.message)
        }
        // A leave (or being removed by an administrator) ends the screen: the channel is no longer mine to
        // inspect, and leaving the sheet open would show a channel I cannot open. This handler belongs to
        // the view that *observes* the model — `ChannelInfoSheet` holds it as a plain `@State`, so an
        // `.onChange` there never fires (measured by the live suite: the sheet stayed open).
        .onChange(of: model.didLeave) { _, didLeave in
            guard didLeave else { return }
            coordinator.forget(serverID: server.id, channelID: model.channelID)
            onClose()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var headerSection: some View {
        if let header = model.header {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: header.kind.glyph)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(header.title)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("channelInfo.title")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Text(header.typeLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !header.membersText.isEmpty {
                            Text(header.membersText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("channelInfo.memberCount")
                        }
                    }
                    if header.isArchived {
                        Label("This channel is archived.", systemImage: "archivebox")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("channelInfo.archivedBanner")
                    }
                }
                .padding(.vertical, 2)

                if !header.purpose.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Purpose").font(.caption).foregroundStyle(.secondary)
                        Text(header.purpose)
                            .font(.callout)
                            .accessibilityIdentifier("channelInfo.purpose")
                    }
                }
                if !header.header.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Header").font(.caption).foregroundStyle(.secondary)
                        Text(header.header)
                            .font(.callout)
                            .accessibilityIdentifier("channelInfo.header")
                    }
                }
            }
        }
    }

    /// T8525: upstream's channel-info "Ignore @channel, @here, @all" toggle
    /// (`app/screens/channel_info/options/ignore_mentions/`, drawn for every type but a direct message).
    ///
    /// The switch's state is **derived** from the server (`ChannelMentionIgnoreToggle`), never held as a
    /// local flag: the channel value, or the account's `notify_props.channel` when the channel says
    /// `"default"`. A value this build does not know is quoted with the server's own string and cannot be
    /// flipped — the tap would rewrite a setting nobody here understands.
    @ViewBuilder
    private var ignoreMentionsSection: some View {
        if model.showsIgnoreMentionsSwitch {
            Section {
                switch model.ignoreMentionsState {
                case .ignoring, .notIgnoring:
                    Toggle(isOn: Binding(
                        get: { model.isIgnoringMentions },
                        set: { ignoring in
                            Task { await model.setIgnoreMentions(ignoring) }
                        })) {
                        Label("Ignore @channel, @here, @all", systemImage: "at")
                    }
                    .disabled(!model.canToggleIgnoreMentions)
                    .accessibilityIdentifier("channelInfo.ignoreMentions")
                case .unknown(let raw):
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Ignore @channel, @here, @all: \(raw)", systemImage: "at")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("This build does not know that value, so it is shown as the server sent it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("channelInfo.ignoreMentions.unknown")
                case .unreadable:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your mention setting for this channel could not be read.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("channelInfo.ignoreMentions.unreadable")
                        Button("Try again") {
                            Task { await model.refreshNotifyProps() }
                        }
                        .accessibilityIdentifier("channelInfo.ignoreMentions.retry")
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Channel-wide mentions stop notifying you; a message that names you still does.")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            ForEach(model.actions, id: \.self) { action in
                actionRow(action)
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ action: ChannelInfoActionID) -> some View {
        switch action {
        case .addMembers:
            Button {
                sheet = .addMembers
            } label: {
                rowLabel("Add members", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier(action.identifier)
        case .members:
            Button {
                showsMembers = true
            } label: {
                HStack {
                    rowLabel("Members", systemImage: "person.2")
                    Spacer()
                    if !model.memberCountText.isEmpty {
                        Text(model.memberCountText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier(action.identifier)
        // T52 rows. All three are the reader's own view of the channel, not an administrator write, so
        // no permission gates them beyond `hasChannel` (`ChannelInfoCapabilities.offeredActions`).
        case .notifications:
            Button {
                showsNotifications = true
            } label: {
                HStack {
                    rowLabel("Notification preferences", systemImage: "bell")
                    Spacer()
                    if !model.notificationSummary.isEmpty {
                        Text(model.notificationSummary)
                            .foregroundStyle(.secondary)
                            .mmLineLimit(1)
                    }
                }
            }
            .accessibilityIdentifier(action.identifier)
        case .files:
            Button {
                // T52-R3: the model is built here, from the tap, and the push only happens when it
                // exists — the earlier shape pushed first and left a permanent spinner when the model
                // could not be built (and nothing in the tree said which of the two had happened).
                if let created = model.makeChannelFilesModel() {
                    filesModel = created
                    showsFiles = true
                } else {
                    model.reportFilesUnavailable()
                }
            } label: {
                rowLabel("Files", systemImage: "paperclip")
            }
            .accessibilityIdentifier(action.identifier)
        case .pinned:
            // The sheet is T39's and it navigates, so a host with no navigation model gets no row
            // (rather than a row whose tap presents nothing).
            if navigation != nil {
                Button {
                    sheet = .pinned
                } label: {
                    rowLabel("Pinned messages", systemImage: "pin")
                }
                .accessibilityIdentifier(action.identifier)
            }
        case .settings:
            Button {
                showsSettings = true
            } label: {
                rowLabel("Channel settings", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier(action.identifier)
        case .convertToChannel:
            // The tap builds the model; a row whose screen cannot be built reports why (the same rule as
            // the files row above) instead of pushing a spinner nothing fills in.
            Button {
                if let created = model.makeConversionModel(conversions: navigation) {
                    conversionModel = created
                    showsConvert = true
                } else {
                    model.reportConversionUnavailable()
                }
            } label: {
                rowLabel(ConvertGMToChannelCopy.actionTitle, systemImage: "lock")
            }
            .accessibilityIdentifier(action.identifier)
        case .archive:
            Button {
                confirmArchive = true
            } label: {
                rowLabel("Archive channel", systemImage: "archivebox")
            }
            .accessibilityIdentifier(action.identifier)
        case .unarchive:
            Button {
                confirmUnarchive = true
            } label: {
                rowLabel("Unarchive channel", systemImage: "archivebox.fill")
            }
            .accessibilityIdentifier(action.identifier)
        case .leave:
            Button(role: .destructive) {
                confirmLeave = true
            } label: {
                rowLabel(leaveTitle, systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
            .accessibilityIdentifier(action.identifier)
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }

    /// T52: the teams a group message's members share, drawn only when the server named one.
    ///
    /// The route is measured to answer 400 for every channel type except `G`, so the model asks only
    /// for a group message and this section is empty everywhere else. On this single-team fixture the
    /// answer for a GM is the one team its members have in common — the server decides what is common,
    /// and the row repeats its answer rather than guessing at Connected Workspaces.
    @ViewBuilder
    private var sharedTeamsSection: some View {
        let summary = ChannelSharedTeamsDerivation.summary(model.commonTeams)
        if !summary.isEmpty {
            Section {
                Label(summary, systemImage: "arrow.left.arrow.right")
                    .accessibilityIdentifier("channelInfo.sharedTeams")
            } header: {
                Text("Shared with")
            }
        }
    }

    // MARK: Copy

    /// "Leave channel" for a channel, "Close direct message" / "Close group message" for a DM/GM — the
    /// row must say which write it performs (`ChannelLeavePrompt.action`).
    private var leaveTitle: String {
        ChannelLeavePrompt.make(kind: model.capabilities.kind,
                                displayName: model.header?.title ?? "").title
    }

    private var leavePrompt: ChannelLeavePrompt {
        ChannelLeavePrompt.make(kind: model.capabilities.kind,
                                displayName: model.header?.title ?? "this channel")
    }

    private var archivePrompt: ChannelArchivePrompt {
        ChannelArchivePrompt.archive(kind: model.capabilities.kind,
                                     displayName: model.header?.title ?? "this channel")
    }

    private var unarchivePrompt: ChannelArchivePrompt {
        ChannelArchivePrompt.unarchive(kind: model.capabilities.kind,
                                       displayName: model.header?.title ?? "this channel")
    }
}
