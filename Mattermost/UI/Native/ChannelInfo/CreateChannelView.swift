// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/create_or_edit_channel/create_or_edit_channel.tsx (create mode: the public/private
//        segmented control, the display name field, the URL name field derived from it, the purpose and
//        header fields with their counters, and the Create button),
//        app/screens/create_or_edit_channel/channel_info_form.tsx (the field order).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// The form owns **no rules and no request**: `ChannelCreateDraft` decides what is valid and what the body
// is, `ChannelCreateViewModel` refuses a kind this reader may not create and performs the write. The view
// is drawn by a second struct (`CreateChannelForm`) that observes the model — the defect T40-R measured
// on two other forms was a `@State`-held `ObservableObject`, which never re-renders, so a Save/Create
// button kept the disabled state it was born with.

import SwiftUI

/// The create-channel sheet.
struct CreateChannelView: View {
    @ObservedObject var model: ChannelCreateViewModel
    /// The created channel, handed to the host so it can land on it through `NativeNavigation`.
    let onCreated: (MMChannel) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CreateChannelForm(model: model) { channel in
                dismiss()
                onCreated(channel)
            }
            .navigationTitle("Create a channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("createChannel.cancel")
                }
            }
        }
        .task {
            // The host may hand over a model that already loaded (the menu needed the same permission
            // answer); loading twice would be two `POST /roles/names`.
            if model.phase != .ready { await model.load() }
        }
        .accessibilityIdentifier("createChannel.sheet")
    }
}

/// The form itself — separate so the model is **observed** (see the note at the top of this file).
struct CreateChannelForm: View {
    @ObservedObject var model: ChannelCreateViewModel
    let onCreated: (MMChannel) -> Void

    var body: some View {
        Form {
            if case .failed(let message) = model.phase {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("createChannel.error")
                    Button("Try again") { Task { await model.load() } }
                        .accessibilityIdentifier("createChannel.retry")
                }
            }

            Section {
                if model.showsKindToggle {
                    Picker("Type", selection: kindBinding) {
                        ForEach(model.creatableKinds, id: \.rawValue) { kind in
                            Text(kind.typeLabel).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("createChannel.kind")
                } else if let only = model.creatableKinds.first {
                    LabeledContent("Type", value: only.typeLabel)
                        .accessibilityIdentifier("createChannel.kindFixed")
                }

                LabeledContent {
                    TextField("Name", text: displayNameBinding)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("createChannel.displayName")
                } label: {
                    Text("Name")
                }
                if let counter = counter(model.draft.displayName,
                                         limit: ChannelCreateDraft.maxDisplayNameLength) {
                    Text(counter).font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("URL").font(.caption).foregroundStyle(.secondary)
                    TextField("URL", text: urlNameBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("createChannel.urlName")
                    Text("This is the address of the channel, e.g. /channels/\(model.draft.urlName.isEmpty ? "…" : model.draft.urlName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("createChannel.urlNameHint")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Purpose").font(.caption).foregroundStyle(.secondary)
                    TextField("Purpose", text: purposeBinding, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("createChannel.purpose")
                    if let counter = counter(model.draft.purpose, limit: ChannelCreateDraft.maxPurposeLength) {
                        Text(counter).font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Header").font(.caption).foregroundStyle(.secondary)
                    TextField("Header", text: headerBinding, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("createChannel.header")
                    if let counter = counter(model.draft.header, limit: ChannelCreateDraft.maxHeaderLength) {
                        Text(counter).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let validation = model.validationMessage {
                    Text(validation)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("createChannel.validation")
                }

                Button {
                    Task {
                        if let channel = await model.create() { onCreated(channel) }
                    }
                } label: {
                    HStack {
                        Text("Create")
                        Spacer()
                        if model.isCreating { ProgressView() }
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("createChannel.submit")

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("createChannel.createError")
                }
            } footer: {
                Text(model.draft.kind == .open
                     ? "Anyone on this team can find and join a public channel."
                     : "A private channel is only visible to the people you invite.")
            }
        }
        .accessibilityIdentifier("createChannel.form")
    }

    // MARK: Bindings
    //
    // Each keystroke goes through the draft's own mutators, so the URL name follows the display name
    // until the reader types in it — the rule lives in `ChannelCreateDraft`, not here.

    private var displayNameBinding: Binding<String> {
        Binding(get: { model.draft.displayName },
                set: { model.draft.setDisplayName($0) })
    }

    private var urlNameBinding: Binding<String> {
        Binding(get: { model.draft.urlName },
                set: { model.draft.setURLName($0) })
    }

    private var purposeBinding: Binding<String> {
        Binding(get: { model.draft.purpose }, set: { model.draft.purpose = $0 })
    }

    private var headerBinding: Binding<String> {
        Binding(get: { model.draft.header }, set: { model.draft.header = $0 })
    }

    private var kindBinding: Binding<ChannelInfoKind> {
        Binding(get: { model.draft.kind },
                set: { model.setKind($0) })
    }

    /// A counter appears only near the limit (80%), the same rule as the settings form: a number on
    /// every field is noise.
    private func counter(_ text: String, limit: Int) -> String? {
        guard text.count >= Int(Double(limit) * 0.8) else { return nil }
        return "\(text.count)/\(limit)"
    }
}
