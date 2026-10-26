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
// The whole screen is behind `Surface.channelInfo`, which is `.web` until T40-AV approves the flip:
// `ChannelPaneContent` only draws the header button that opens this sheet when the resolver says the
// surface is native, so with the flag off the web app's own channel menu is the only one.

import SwiftUI

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

    @EnvironmentObject private var coordinator: ChannelInfoCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChannelInfoViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ChannelInfoView(model: model, server: server, onClose: { dismiss() })
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
        // A leave (or being removed by an administrator) ends the screen: the channel is no longer mine
        // to inspect, and leaving the sheet open would show a channel I cannot open.
        .onChange(of: model?.didLeave ?? false) { _, didLeave in
            if didLeave {
                coordinator.forget(serverID: server.id, channelID: channelID)
                dismiss()
            }
        }
        .accessibilityIdentifier("channelInfo.sheet")
    }
}

/// The channel-info screen: what this channel is, who is in it, and what I may do to it.
struct ChannelInfoView: View {
    @ObservedObject var model: ChannelInfoViewModel
    let server: ServerConfig
    let onClose: () -> Void

    @State private var confirmLeave = false
    @State private var confirmArchive = false
    @State private var confirmUnarchive = false
    @State private var showsAddMembers = false
    @State private var showsMembers = false
    @State private var showsSettings = false

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
                actionsSection
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
        .sheet(isPresented: $showsAddMembers) {
            AddMembersView(model: model, server: server)
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
                showsAddMembers = true
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
        case .settings:
            Button {
                showsSettings = true
            } label: {
                rowLabel("Channel settings", systemImage: "slider.horizontal.3")
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
