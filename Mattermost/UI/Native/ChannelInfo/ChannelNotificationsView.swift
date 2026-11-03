// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_notification_preferences/channel_notification_preferences.tsx (the
//        screen: the Notifications level radio list, the "Mute channel" switch, the
//        "Ignore @channel/@all/@here" switch, and Save),
//        app/screens/channel_notification_preferences/notification_levels.ts, and the
//        `updateChannelNotifyProps` call in app/actions/remote/channel.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// The screen is a **draft** over the server's own strings (`ChannelNotifyDraft`): it starts from what
// `GET …/members/{uid}` answered, Save sends only fields the reader changed to a value this build
// knows, and the model then replaces the draft with the server's read-back. Two consequences a reader
// can see:
//   * a level this build does not recognise is drawn as "Server setting: <raw>" rather than being
//     mapped to "Account default" — the server stores strings it does not validate (measured), so a
//     newer server's vocabulary must not be silently rewritten by an older client;
//   * a preference this client could not read shows a Retry, never a default the reader never chose.
//
// Mute is `mark_unread == "mention"` — the sidebar's context-menu mute writes the same field, so both
// entries are one fact and the card keeps the context menu working.

import SwiftUI

struct ChannelNotificationsView: View {
    @ObservedObject var model: ChannelInfoViewModel

    var body: some View {
        Group {
            if let server = model.notifyDraft, server.isReadable {
                ChannelNotificationsForm(model: model, server: server)
            } else if model.phase == .ready {
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Your notification preferences could not be read.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("channelInfo.notifications.unreadable")
                    Text("Nothing is offered here until the server answers: a level this screen guessed "
                         + "could save a preference you never chose.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        Task { await model.refreshNotifyProps() }
                    }
                    .accessibilityIdentifier("channelInfo.notifications.retry")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Notification preferences")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The info screen's load already read the membership; only a failed read is retried here.
            if !model.notificationsReadable {
                await model.refreshNotifyProps()
            }
        }
    }
}

/// The form itself. A separate view so its `@State` draft is what SwiftUI observes (the same
/// T40-AV F2 lesson as the channel-settings form: a draft held unobserved never re-enables Save).
struct ChannelNotificationsForm: View {
    @ObservedObject var model: ChannelInfoViewModel

    /// The server's answer when the form opened — the baseline a save is diffed against.
    @State private var baseline: ChannelNotifyDraft
    @State private var draft: ChannelNotifyDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSave = false

    init(model: ChannelInfoViewModel, server: ChannelNotifyDraft) {
        self.model = model
        _baseline = State(initialValue: server)
        _draft = State(initialValue: server)
    }

    private var changedFields: [String: String] {
        draft.changedFields(comparedTo: baseline)
    }

    private var canSave: Bool {
        !isSaving && !changedFields.isEmpty
    }

    var body: some View {
        Form {
            Section {
                ForEach(ChannelNotifyDesktopLevel.allCases, id: \.self) { level in
                    Button {
                        draft = draft.setting(desktop: level)
                        didSave = false
                    } label: {
                        HStack {
                            Text(level.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if draft.desktopLevel == level {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityIdentifier("channelInfo.notifications.desktop.\(level.rawValue)")
                    .accessibilityAddTraits(draft.desktopLevel == level ? .isSelected : [])
                }
                if let raw = draft.desktop, draft.desktopLevel == nil {
                    unrecognisedRow("Notifications", raw: raw,
                                    identifier: "channelInfo.notifications.unknown.desktop")
                }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Account default follows your account's own notification setting. "
                     + "Mentions and keywords still notify you when the channel is muted.")
            }

            Section {
                Toggle("Mute channel", isOn: Binding(
                    get: { draft.isMuted },
                    set: { muted in
                        draft = draft.setting(markUnread: muted ? .mention : .all)
                        didSave = false
                    }))
                    .accessibilityIdentifier("channelInfo.notifications.mute")
                if let raw = draft.markUnread, draft.markUnreadLevel == nil {
                    unrecognisedRow("Mute channel", raw: raw,
                                    identifier: "channelInfo.notifications.unknown.mute")
                }
            } footer: {
                Text("Muted channels only notify you for mentions and keywords. "
                     + "This is the same setting the channel's context-menu mute writes.")
            }

            Section {
                Toggle("Ignore @channel, @all and @here", isOn: Binding(
                    get: { draft.ignoresChannelMentions },
                    set: { ignore in
                        draft = draft.setting(ignoreMentions: ignore ? .on : .off)
                        didSave = false
                    }))
                    .accessibilityIdentifier("channelInfo.notifications.ignoreMentions")
                if let raw = draft.ignoreMentions, draft.ignoreMentionsLevel == nil {
                    unrecognisedRow("Ignore @mentions", raw: raw,
                                    identifier: "channelInfo.notifications.unknown.ignore")
                }
            } footer: {
                Text("Ignoring channel-wide mentions still notifies you when you are named directly.")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text("Save")
                        Spacer()
                        if isSaving { ProgressView() }
                    }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("channelInfo.notifications.save")

                if didSave {
                    Text("Saved")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("channelInfo.notifications.saved")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("channelInfo.notifications.error")
                }
            }
        }
        .accessibilityIdentifier("channelInfo.notifications.form")
    }

    private func unrecognisedRow(_ field: String, raw: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(field): \(raw)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("This build does not know that value, so it is shown as the server sent it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func save() async {
        let body = changedFields
        guard !body.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        didSave = false
        let succeeded = await model.saveNotifyProps(draft)
        isSaving = false
        if succeeded {
            // The model re-read the membership: the form follows the server, not the tap.
            let stored = model.notifyDraft ?? draft
            baseline = stored
            draft = stored
            didSave = true
        } else {
            errorMessage = model.banner ?? "Your notification preferences could not be saved."
        }
    }
}
