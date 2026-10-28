// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/create_direct_message/ (the people list with its search field and the tap that
//        opens the conversation), app/actions/remote/channel.ts (`createDirectChannel`),
//        app/client/rest/users.ts (`getProfilesInTeam`, `searchProfiles`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// One tap opens the conversation: the row already names the person, so a select-then-Start flow would
// ask the same question twice. The write is `POST /channels/direct` (the only channel-creation call the
// server offers for a DM — `POST /channels` refuses `type: D`, measured), and the created-or-found
// channel is handed to the host, which navigates through `NativeNavigation.openChannel`.
//
// The list is drawn by `NewDirectMessageList`, a second struct that **observes** the model — the
// `@State`-held-model defect T40-R measured on three other surfaces (a model in plain `@State` never
// re-renders, so a joiner spinner, an error sentence or a result list simply never appeared).

import SwiftUI

struct NewDirectMessageView: View {
    @ObservedObject var model: NewDirectMessageViewModel
    let onOpened: (MMChannel) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NewDirectMessageList(model: model) { channel in
                dismiss()
                onOpened(channel)
            }
            .navigationTitle("New direct message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("newDM.cancel")
                }
            }
        }
        .task { if model.phase != .ready { await model.load() } }
        .accessibilityIdentifier("newDM.sheet")
    }
}

struct NewDirectMessageList: View {
    @ObservedObject var model: NewDirectMessageViewModel
    let onOpened: (MMChannel) -> Void

    var body: some View {
        List {
            switch model.phase {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("newDM.error")
                Button("Try again") { Task { await model.load() } }
                    .accessibilityIdentifier("newDM.retry")
            case .ready:
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("newDM.openError")
                }
                if model.rows.isEmpty {
                    Text(model.emptyCopy)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("newDM.empty")
                }
                ForEach(model.rows) { candidate in
                    Button {
                        Task {
                            if let channel = await model.open(candidate) { onOpened(channel) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(candidate.initials)
                                .font(.caption.weight(.semibold))
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.15), in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName)
                                    .foregroundStyle(.primary)
                                Text("@\(candidate.username)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.isOpening {
                                ProgressView()
                            } else if !candidate.status.isEmpty {
                                Text(candidate.statusLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("newDM.row.\(candidate.id)")
                    .accessibilityLabel(candidate.displayName)
                }
            }
        }
        .searchable(text: Binding(get: { model.term }, set: { model.term = $0 }),
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search people")
        .onSubmit(of: .search) { Task { await model.search(model.term) } }
        .onChange(of: model.term) { _, newValue in
            // An empty field goes back to the team list; anything typed is a search. The model owns the
            // decision (and the generation guard that drops a stale answer).
            Task { await model.search(newValue) }
        }
        .accessibilityIdentifier("newDM.list")
    }
}
