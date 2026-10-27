// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/custom_status/index.tsx (the status setter: the four presence options, the
//        "custom status" row and the "clear" row), app/screens/custom_status/clear_after/
//        (the duration list), app/screens/custom_status/custom_status_emoji/ (the emoji field),
//        app/screens/custom_status_clear_after/clear_after.tsx (the DND end-time list),
//        app/components/custom_status/custom_status_input.tsx (the emoji + text editor).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// Two screens, both **pushed** on the profile's navigation stack (never presented as a sheet from
// inside the profile sheet — see ProfileView's header for the measured reason).
//
// The emoji field is a curated grid rather than T37's `EmojiPickerView`: that view is a sheet with its
// own `NavigationStack` and detents, and nesting it here is the defect class T40's validator measured.
// The names in `CustomStatusEmoji.palette` are verified against the server by
// `scripts/t41_profile_probe.py`, because the server rejects an emoji it does not know with a 400
// (`confirmEmojiExists`).
//
// Identifiers an XCUITest can rely on (also listed in docs/t41-build-note.md §4):
//   statusSetter                    the setter screen
//   statusSetter.option.<presence>  the four presence rows (online/away/dnd/offline)
//   statusSetter.current            the "current status" line
//   statusSetter.dnd.<wireValue>    a DND end-time choice (thirty_minutes/one_hour/four_hours/today)
//   statusSetter.custom             opens the custom status editor
//   statusSetter.clear              clears the custom status
//   statusSetter.done               back
//   statusSetter.banner             a write failure
//   customStatus.editor             the custom status editor
//   customStatus.emoji.<name>       an emoji cell
//   customStatus.text               the text field
//   customStatus.duration.<wire>    a duration row ("" → doNotClear)
//   customStatus.validation         the refusal copy
//   customStatus.save               save
//   customStatus.clear              clear
//   customStatus.done               back

import SwiftUI

/// The status setter: presence, an optional DND end time, and the way into the custom status.
struct StatusSetterScreen: View {
    @ObservedObject var model: ProfileViewModel
    /// The DND end-time choices this host offers (defaults to the four fixed windows).
    var dndChoices: [StatusDuration] = StatusDuration.dndChoices

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDND: StatusDuration = .thirtyMinutes
    @State private var showsCustomStatusEditor = false

    var body: some View {
        List {
            Section {
                ForEach(UserPresence.selectable) { presence in
                    Button {
                        Task { await model.setPresence(presence,
                                                       dndDuration: presence == .dnd ? pendingDND : nil) }
                    } label: {
                        HStack(spacing: 12) {
                            PresenceDot(presence: presence, size: 12)
                                .padding(.leading, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(presence.title)
                                    .foregroundStyle(.primary)
                                Text(presence.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if model.selectedPresence == presence {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .disabled(model.isWriting)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("statusSetter.option.\(presence.rawValue)")
                }
            } header: {
                Text("Status")
            } footer: {
                if let current = model.selectedPresence {
                    Text("You are \(current.title.lowercased()).")
                        .accessibilityIdentifier("statusSetter.current")
                }
            }

            Section {
                // Rows only, no `Picker`: an inline picker draws every option *and* these rows draw
                // each one again, which is what the shipped screenshot showed (eight rows for four
                // choices, two ticks on "30 minutes"). The rows carry the identifiers the live test
                // taps, so they are the control — one control, one look.
                ForEach(dndChoices) { choice in
                    Button {
                        pendingDND = choice
                        Task { await model.setPresence(.dnd, dndDuration: choice) }
                    } label: {
                        HStack {
                            Text(choice.title)
                            Spacer()
                            if pendingDND == choice {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .disabled(model.isWriting)
                    .accessibilityIdentifier("statusSetter.dnd.\(choice.wireValue)")
                }
            } header: {
                Text("Do not disturb clears after")
            } footer: {
                Text("Choose how long do not disturb lasts. It clears on the server, so every client "
                     + "sees the same end time.")
            }

            Section {
                Button {
                    showsCustomStatusEditor = true
                } label: {
                    Label(model.activeCustomStatus == nil ? "Set a custom status" : "Edit custom status",
                          systemImage: "face.smiling")
                }
                .accessibilityIdentifier("statusSetter.custom")

                if let status = model.activeCustomStatus {
                    Button(role: .destructive) {
                        Task { await model.clearCustomStatus() }
                    } label: {
                        Label("Clear custom status", systemImage: "xmark.circle")
                    }
                    .disabled(model.isWriting)
                    .accessibilityIdentifier("statusSetter.clear")
                    if let text = ProfileDateFormat.customStatusText(status, now: Date()) {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Custom status")
            }

            if let banner = model.banner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("statusSetter.banner")
                }
            }
        }
        .navigationTitle("Set a status")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("statusSetter.done")
            }
        }
        .navigationDestination(isPresented: $showsCustomStatusEditor) {
            CustomStatusEditorScreen(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusSetter")
    }
}

/// The custom status editor: emoji, text and how long it lasts.
struct CustomStatusEditorScreen: View {
    @ObservedObject var model: ProfileViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft = CustomStatusDraft()
    @State private var didSeed = false

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 8)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(CustomStatusEmoji.palette, id: \.self) { name in
                        Button {
                            draft.emoji = name
                        } label: {
                            Text(SystemEmojiCatalogue.shared.character(for: name) ?? ":\(name):")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(draft.emoji == name
                                            ? Color.accentColor.opacity(0.22)
                                            : Color(.secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(CustomStatusEmoji.spokenName(name))
                        .accessibilityIdentifier("customStatus.emoji.\(name)")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Emoji")
            } footer: {
                Text("These are the status emoji this app offers. The full picker lives on the message "
                     + "composer, where a sheet is allowed.")
            }

            Section {
                TextField("What's your status?", text: $draft.text, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("customStatus.text")
            } header: {
                Text("Status text")
            } footer: {
                Text("\(Array(draft.trimmedText).count)/\(CustomStatusDraft.textLimit) characters. "
                     + "The server keeps the first \(CustomStatusDraft.textLimit).")
            }

            Section {
                ForEach(StatusDuration.allCases) { duration in
                    Button {
                        draft.duration = duration
                        if duration == .dateAndTime, draft.customExpiry == nil {
                            // Default the picker to an hour from now so "choose a date and time" has a
                            // value the moment it is selected (an empty picker reads as broken).
                            draft.customExpiry = Date().addingTimeInterval(3600)
                        }
                    } label: {
                        HStack {
                            Text(duration.title)
                            Spacer()
                            if draft.duration == duration {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityIdentifier("customStatus.duration.\(duration.wireValue)")
                }
                if draft.duration == .dateAndTime {
                    DatePicker("Clears at",
                               selection: Binding(get: { draft.customExpiry ?? Date().addingTimeInterval(3600) },
                                                  set: { draft.customExpiry = $0 }),
                               in: Date()...,
                               displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("customStatus.expiry")
                }
            } header: {
                Text("Clears after")
            }

            if let message = draft.validationMessage(at: Date()) {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("customStatus.validation")
                }
            }
            if let banner = model.banner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("customStatus.banner")
                }
            }

            Section {
                if model.activeCustomStatus != nil {
                    Button(role: .destructive) {
                        Task {
                            if await model.clearCustomStatus() { dismiss() }
                        }
                    } label: {
                        Label("Clear custom status", systemImage: "trash")
                    }
                    .disabled(model.isWriting)
                    .accessibilityIdentifier("customStatus.clear")
                }
            }
        }
        .navigationTitle("Custom status")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Save lives in the bar, not in a `Form` row: a long form scrolls its rows out of the
            // accessibility tree, and a primary action that the reader (or a test) has to scroll to
            // find is a worse control than one that is always in the same place.
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("customStatus.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        if await model.saveCustomStatus(draft) { dismiss() }
                    }
                }
                .disabled(!draft.canSave(at: Date()) || model.isWriting)
                .accessibilityIdentifier("customStatus.save")
            }
        }
        .onAppear {
            // Seed from the status the server holds, once: re-seeding on every appearance would
            // discard what the reader typed when a write failed and they came back.
            guard !didSeed else { return }
            didSeed = true
            if let status = model.profile?.customStatus {
                draft = CustomStatusDraft(status: status)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("customStatus.editor")
    }
}
