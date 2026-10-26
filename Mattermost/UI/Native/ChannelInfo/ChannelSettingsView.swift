// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/create_or_edit_channel/create_or_edit_channel.tsx (the edit form, its Save button
//        and the `{display_name, purpose, header}` patch), channel_info_form.tsx (field order, the
//        64/250/1024 limits and their counters), app/screens/channel_settings/archive/archive.tsx
//        (the archive/unarchive rows and their confirmations).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// The form is a **draft**: it starts from what the server answered, saves only the fields that changed
// (`ChannelPatchDraft.patch`), and refuses locally at the same limits the server enforces (measured:
// display name 64, purpose 250, header 1024 — `model.channel.is_valid.*`). A DM/GM gets the header field
// only, which is what upstream sends for one.

import SwiftUI

struct ChannelSettingsView: View {
    @ObservedObject var model: ChannelInfoViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var form: ChannelSettingsViewModel?
    @State private var confirmArchive = false
    @State private var confirmUnarchive = false

    var body: some View {
        Group {
            if let channel = model.channel {
                content(channel: channel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Channel settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if form == nil, let channel = model.channel {
                form = ChannelSettingsViewModel(channel: channel)
            }
        }
    }

    @ViewBuilder
    private func content(channel: MMChannel) -> some View {
        if let form {
            Form {
                Section {
                    if form.showsNameAndPurpose {
                        LabeledContent {
                            TextField("Name", text: Binding(get: { form.draft.displayName },
                                                            set: { form.draft.displayName = $0 }))
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("channelSettings.name")
                        } label: {
                            Text("Name")
                        }
                        if let counter = form.nameCounter(form.draft.displayName) {
                            Text(counter).font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Purpose").font(.caption).foregroundStyle(.secondary)
                            TextField("Purpose", text: Binding(get: { form.draft.purpose },
                                                               set: { form.draft.purpose = $0 }),
                                      axis: .vertical)
                                .lineLimit(2...4)
                                .accessibilityIdentifier("channelSettings.purpose")
                            if let counter = form.purposeCounter(form.draft.purpose) {
                                Text(counter).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Header").font(.caption).foregroundStyle(.secondary)
                        TextField("Header", text: Binding(get: { form.draft.header },
                                                          set: { form.draft.header = $0 }),
                                  axis: .vertical)
                            .lineLimit(2...5)
                            .accessibilityIdentifier("channelSettings.header")
                        if let counter = form.headerCounter(form.draft.header) {
                            Text(counter).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let validation = form.validationMessage {
                        Text(validation)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("channelSettings.validation")
                    }
                } footer: {
                    if !form.showsNameAndPurpose {
                        Text("A direct message's name comes from its members.")
                    }
                }

                Section {
                    Button {
                        Task { await save(form) }
                    } label: {
                        HStack {
                            Text("Save")
                            Spacer()
                            if form.isSaving { ProgressView() }
                        }
                    }
                    .disabled(!form.canSave)
                    .accessibilityIdentifier("channelSettings.save")
                    if let error = form.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("channelSettings.error")
                    }
                }

                // Archive lives here because upstream keeps it in the channel-settings screen; the info
                // screen also offers it as a row, which is where a reader looks first.
                if model.capabilities.canArchive {
                    Section {
                        Button(role: .destructive) {
                            confirmArchive = true
                        } label: {
                            Label("Archive channel", systemImage: "archivebox")
                                .foregroundStyle(.red)
                        }
                        .accessibilityIdentifier("channelSettings.archive")
                    }
                }
                if model.capabilities.canUnarchive {
                    Section {
                        Button {
                            confirmUnarchive = true
                        } label: {
                            Label("Unarchive channel", systemImage: "archivebox.fill")
                        }
                        .accessibilityIdentifier("channelSettings.unarchive")
                    }
                }
            }
            .confirmationDialog(archivePrompt.title, isPresented: $confirmArchive,
                                titleVisibility: .visible) {
                Button("Archive", role: .destructive) {
                    Task {
                        if await model.archive() { dismiss() }
                    }
                }
                .accessibilityIdentifier("channelSettings.archive.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(archivePrompt.message)
            }
            .confirmationDialog(unarchivePrompt.title, isPresented: $confirmUnarchive,
                                titleVisibility: .visible) {
                Button("Unarchive") {
                    Task { await model.unarchive() }
                }
                .accessibilityIdentifier("channelSettings.unarchive.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(unarchivePrompt.message)
            }
            .accessibilityIdentifier("channelSettings.form")
        }
    }

    private func save(_ form: ChannelSettingsViewModel) async {
        guard let patch = form.patch else { return }
        form.beginSaving()
        let succeeded = await model.save(patch)
        form.finishSaving(succeeded: succeeded, message: model.banner)
        if succeeded {
            dismiss()
        }
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
