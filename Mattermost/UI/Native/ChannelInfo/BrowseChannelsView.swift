// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/browse_channels/browse_channels.tsx (the two sections: channels I am in, other
//        public channels; the search field; the archived rows), search_handler.tsx (the term filter),
//        channel_list.tsx (the row and its tap).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// The card's criterion: "joining a public channel from the browser navigates straight into it". The tap
// therefore completes the join **and** opens the channel — the reader never lands back on a list and
// hunts for the channel in the sidebar.

import SwiftUI

struct BrowseChannelsView: View {
    let server: ServerConfig
    let teamID: String

    @EnvironmentObject private var coordinator: ChannelInfoCoordinator
    @EnvironmentObject private var navigation: NativeNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var model: BrowseChannelsViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Browse channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("browseChannels.done")
                }
            }
        }
        .task {
            let created = coordinator.browseModel(for: server, teamID: teamID)
            model = created
            await created.load()
        }
        .accessibilityIdentifier("browseChannels.sheet")
    }

    @ViewBuilder
    private func content(_ model: BrowseChannelsViewModel) -> some View {
        List {
            switch model.phase {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("browseChannels.error")
                Button("Try again") { Task { await model.load() } }
            case .ready:
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("browseChannels.joinError")
                }
                let sections = model.sections
                if sections.joined.isEmpty && sections.others.isEmpty {
                    Text(model.term.isEmpty ? "There are no channels to browse."
                                            : "No channel matches “\(model.term)”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("browseChannels.empty")
                }
                if !sections.joined.isEmpty {
                    Section("Channels you are in") {
                        ForEach(sections.joined) { entry in
                            row(entry, model: model)
                        }
                    }
                }
                if !sections.others.isEmpty {
                    Section {
                        ForEach(sections.others) { entry in
                            row(entry, model: model)
                        }
                    } header: {
                        Text("Other public channels")
                    } footer: {
                        if let note = model.truncationNote {
                            Text(note)
                        }
                    }
                }
            }
        }
        .searchable(text: Binding(get: { model.term }, set: { model.term = $0 }),
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search channels")
        .accessibilityIdentifier("browseChannels.list")
    }

    @ViewBuilder
    private func row(_ entry: BrowseChannelEntry, model: BrowseChannelsViewModel) -> some View {
        Button {
            Task { await open(entry, model: model) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.kind.glyph)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .foregroundStyle(.primary)
                    if entry.isArchived {
                        Text("Archived")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if model.joiningID == entry.id {
                    ProgressView()
                } else if entry.isMember {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                } else if entry.isJoinable && model.canJoinPublicChannels {
                    Text("Join")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityIdentifier("browseChannels.row.\(entry.id)")
    }

    /// Join (when needed) and go into the channel.
    private func open(_ entry: BrowseChannelEntry, model: BrowseChannelsViewModel) async {
        guard let channelID = await model.join(entry) else { return }
        let target = BrowseChannelsDerivation.joinTarget(for: entry)
        dismiss()
        navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                    teamID: teamID,
                                                    channelID: channelID,
                                                    channelName: target.channelName))
    }
}
