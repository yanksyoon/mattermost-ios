// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/convert_gm_to_channel/convert_gm_to_channel_form/convert_gm_to_channel_form.tsx
//        (the message box, the team selector, the name field, the destructive submit and its two error
//        slots), message_box/message_box.tsx (the bordered warning with its icon), team_selector.tsx
//        (a row that shows the selected team's display name), channel_name_input.tsx (the name field and
//        its error), no_common_teams_form.tsx (the "different teams" state with a Back button).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §25; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// The form owns **no rules and no request**: `ConvertGMToChannelDraft` decides what is valid and what
// the body is, `ConvertGMToChannelViewModel` refuses anything the gate closes and performs the write.
// The screen is a second struct (`ConvertGMToChannelForm`) that observes the model, because a form held
// in a plain `@State` never re-renders (the defect T40-R measured: a button kept the disabled state it
// was born with, and the tap sent nothing).

import SwiftUI

/// The "convert a group message to a private channel" screen.
///
/// Pushed inside the info sheet's own `NavigationStack`, so the reader keeps a Back button to the
/// channel info screen.
struct ConvertGMToChannelView: View {
    @ObservedObject var model: ConvertGMToChannelViewModel
    /// The converted channel: the host closes the sheet and lands on it.
    let onConverted: (ConvertedChannelTarget) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching details…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("convertGM.loading")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not open the conversion", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                        .accessibilityIdentifier("convertGM.loadError")
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                        .accessibilityIdentifier("convertGM.retry")
                }
            case .noCommonTeams:
                noCommonTeams
            case .ready:
                ConvertGMToChannelForm(model: model) { target in
                    dismiss()
                    onConverted(target)
                }
            }
        }
        .navigationTitle("Convert to a private channel")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // One load per presentation: the model is built from the row's tap and dies with it.
            if model.phase == .idle { await model.load() }
        }
        .accessibilityIdentifier("convertGM.screen")
    }

    /// Upstream `no_common_teams_form`: say why, and give the reader the way back — never a form whose
    /// submit the server would refuse with `app.channel.group_message_conversion.incorrect_team`.
    private var noCommonTeams: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ConvertGMToChannelMessageBox(header: ConvertGMToChannelCopy.noCommonTeamsHeader,
                                             text: ConvertGMToChannelCopy.noCommonTeamsBody,
                                             isDanger: true)
                    .accessibilityIdentifier("convertGM.noCommonTeams")
                Button {
                    dismiss()
                } label: {
                    Text("Back")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("convertGM.back")
            }
            .padding(20)
        }
    }
}

/// The form — separate so the model is **observed** (see the note at the top of this file).
struct ConvertGMToChannelForm: View {
    @ObservedObject var model: ConvertGMToChannelViewModel
    let onConverted: (ConvertedChannelTarget) -> Void

    var body: some View {
        Form {
            Section {
                ConvertGMToChannelMessageBox(header: ConvertGMToChannelCopy.warningHeader,
                                             text: model.warningBody,
                                             isDanger: false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } footer: {
                Text("Anyone who is added to the channel will be able to read this conversation's "
                     + "history. This cannot be undone.")
            }

            Section("Channel") {
                if model.showsTeamPicker {
                    Picker(selection: Binding(get: { model.draft.teamID ?? "" },
                                              set: { id in
                                                  if let team = model.teams.first(where: { $0.id == id }) {
                                                      model.selectTeam(team)
                                                  }
                                              })) {
                        ForEach(model.teams, id: \.id) { team in
                            Text(team.displayName.isEmpty ? team.name : team.displayName)
                                .tag(team.id)
                        }
                    } label: {
                        Text("Team")
                    }
                    .accessibilityIdentifier("convertGM.team")
                } else if !model.selectedTeamName.isEmpty {
                    LabeledContent("Team", value: model.selectedTeamName)
                        .accessibilityIdentifier("convertGM.teamFixed")
                }
                if let teamError = model.teamErrorMessage {
                    Text(teamError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("convertGM.teamError")
                }

                LabeledContent {
                    TextField("Name", text: displayNameBinding)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("convertGM.name")
                } label: {
                    Text("Name")
                }
                Text("The channel's address will be /channels/\(model.draft.urlName.isEmpty ? "…" : model.draft.urlName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("convertGM.urlName")
                if let nameError = model.nameErrorMessage {
                    Text(nameError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("convertGM.nameError")
                }
                if let validation = model.visibleValidationMessage, model.nameErrorMessage == nil {
                    Text(validation)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("convertGM.validation")
                }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        if let _ = await model.convert(), let target = model.target {
                            onConverted(target)
                        }
                    }
                } label: {
                    HStack {
                        Text(model.isConverting
                             ? ConvertGMToChannelCopy.convertingTitle
                             : "Convert to a private channel")
                        Spacer()
                        if model.isConverting { ProgressView() }
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("convertGM.submit")

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("convertGM.error")
                }
            }
        }
        .accessibilityIdentifier("convertGM.form")
    }

    /// Every keystroke goes through the draft's own mutator, so the URL name follows the display name
    /// until the reader types in it — the rule lives in `ConvertGMToChannelDraft`.
    private var displayNameBinding: Binding<String> {
        Binding(get: { model.draft.displayName },
                set: { model.draft.setDisplayName($0) })
    }
}

/// Upstream `message_box`: a bordered block with an exclamation icon, a bold header and a body.
struct ConvertGMToChannelMessageBox: View {
    let header: String
    let text: String
    var isDanger: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isDanger ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("convertGM.warning.header")
                Text(text)
                    .font(.subheadline)
                    .accessibilityIdentifier("convertGM.warning.body")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDanger ? Color.red.opacity(0.08) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isDanger ? Color.red.opacity(0.16) : Color.secondary.opacity(0.16), lineWidth: 1))
    }
}
