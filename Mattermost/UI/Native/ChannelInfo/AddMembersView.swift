// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_add_members/channel_add_members.tsx (the chosen block, the search field,
//        the paged candidate list, the Add button), app/components/autocomplete/* (the row shape).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// Two things this screen does that are easy to get wrong and are therefore stated here:
//  * it opens on a **list** (an empty search term is not sendable — `POST /users/search` answers
//    400 for it, measured), and the list is "team members not in this channel";
//  * the selection survives a change of term: a reader can pick two people from one search and one from
//    another and press Add once.
//
// ## Why the picker is drawn by a second view (T40-R, finding F1)
//
// The picker's view model is created in `.task`, because it needs the coordinator from the
// environment. It used to be held in a plain `@State` on this struct — and `@State` does **not**
// observe an `ObservableObject`: no `objectWillChange` subscription exists, so publishing `selection`
// or `rows` invalidated nothing. The Add button kept the `.disabled` state it was born with, and the
// live suite measured exactly that: the row tap wrote `selection = 1` into the model while the toolbar
// stayed disabled, so the tap on Add ran no action and no `POST /channels/{id}/members` ever left the
// app. (The retry loop the old test used to "get the button to enable" was compensating for this.)
//
// So this struct only *creates* the model; `AddMembersPickerView` takes it as an `@ObservedObject` and
// owns the toolbar and the list. `ChannelSettingsView` and `BrowseChannelsView` had the same defect and
// are split the same way.

import SwiftUI

struct AddMembersView: View {
    @ObservedObject var model: ChannelInfoViewModel
    let server: ServerConfig

    @EnvironmentObject private var coordinator: ChannelInfoCoordinator
    @State private var picker: AddMembersViewModel?

    var body: some View {
        Group {
            if let picker {
                AddMembersPickerView(picker: picker, model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let created = AddMembersViewModel(channelID: model.channelID,
                                              teamID: model.teamID,
                                              service: coordinator.serviceForSheet(server))
            picker = created
            await created.load()
        }
        .accessibilityIdentifier("addMembers.sheet")
    }
}

/// The picker itself: the chosen block, the search field, the candidate list and the Add button.
///
/// A separate view because it must **observe** the model (see the note at the top of this file): a
/// publish has to re-run the body for the Add button's enabled state and for the rows to follow the
/// model.
struct AddMembersPickerView: View {
    @ObservedObject var picker: AddMembersViewModel
    @ObservedObject var model: ChannelInfoViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add members")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("addMembers.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(picker.submitTitle) {
                            Task { await submit() }
                        }
                        .disabled(!picker.canSubmit)
                        .accessibilityIdentifier("addMembers.submit")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if !picker.selectedRows.isEmpty {
                Section("Selected") {
                    ForEach(picker.selectedRows) { row in
                        HStack {
                            Text(row.displayName)
                            Spacer()
                            Button {
                                picker.toggle(row.id)
                            } label: {
                                Label("Remove from selection", systemImage: "xmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("addMembers.selected.\(row.id)")
                        }
                    }
                }
            }
            Section {
                switch picker.phase {
                case .idle, .loading:
                    ProgressView()
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("addMembers.error")
                case .ready:
                    if picker.rows.isEmpty {
                        Text(picker.emptyCopy)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("addMembers.empty")
                    }
                    ForEach(picker.rows) { candidate in
                        Button {
                            picker.toggle(candidate.id)
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Color.secondary.opacity(0.18))
                                    Text(candidate.initials)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.displayName)
                                        .foregroundStyle(.primary)
                                    if !candidate.username.isEmpty {
                                        Text("@\(candidate.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if picker.isSelected(candidate.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("addMembers.row.\(candidate.id)")
                    }
                }
            }
        }
        .searchable(text: Binding(get: { picker.term },
                                  set: { picker.term = $0 }),
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search people")
        .onChange(of: picker.term) { _, term in
            // A short debounce: the field must not fire a request per keystroke, and the view model
            // drops a late answer for an older term (`generation`).
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                await picker.search(term)
            }
        }
        .accessibilityIdentifier("addMembers.list")
    }

    private func submit() async {
        let ids = picker.selectedIDs
        let profiles = picker.selectedProfiles
        let succeeded = await model.addMembers(ids, profiles: profiles)
        if succeeded {
            picker.clearSelection()
            dismiss()
        }
    }
}
