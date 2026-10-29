// T5449 C3 — the picker view (upstream's `AddUserToChannelModal` list, ported as a push).
//
// Behaviour reference: mattermost/mattermost @ v9.11.0,
// `webapp/channels/src/components/add_user_to_channel_modal/`. Licence: Apache-2.0 — behaviour
// ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no upstream source copied.
//
// ## Presentation
//
// A **push** on the profile sheet's own `NavigationStack` — never a nested sheet. `ProfileView.swift`'s
// header states the rule this surface inherits: a sheet presented from inside a sheet is T40's
// measured failure (a confirmation action that never ran, zero requests on the wire), and a push has
// no second presentation to lose.
//
// ## Two views, and why
//
// The container owns the *load*; `AddToChannelPickerContent` owns the *drawing* and observes the
// model (`@ObservedObject`). That split is not decoration: `@State` holding a class does **not**
// repaint on the model's `@Published` changes, and a first live run measured exactly that — the
// search field accepted "T5449 picker fixture" (the field's own `value` carried it) while the list
// below it never changed, so the filtered row was never on screen (`build/logs/t5449-c3-ui-add1.log`).
// A `Binding(get:set:)` into a plain parameter is a write nobody is observing.
//
// Identifiers an XCUITest can rely on:
//   addToChannel.picker        the screen
//   addToChannel.search        the filter field
//   addToChannel.row.<id>      one channel (its accessibility value is "Member" once known)
//   addToChannel.empty         no manageable channel (or no search match)
//   addToChannel.alreadyMember the "already a member" sentence (Add is disabled beside it)
//   addToChannel.submit        "Add to channel"
//   addToChannel.banner        a failed read or write

import SwiftUI

struct AddToChannelPickerView: View {
    let server: ServerConfig
    let teamID: String
    /// The account being added.
    let userID: String
    let userDisplayName: String

    @EnvironmentObject private var coordinator: ProfileCoordinator
    @State private var model: AddToChannelPickerViewModel?

    var body: some View {
        Group {
            if let model {
                AddToChannelPickerContent(model: model)
            } else {
                ProgressView("Reading this team's channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("addToChannel.loading")
            }
        }
        .navigationTitle("Add to a channel")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            // The team answer the profile row was drawn from, when it is already cached: the picker
            // then costs one request per selection and nothing to open.
            let answer = coordinator.channelAdminAnswer(serverID: server.id, teamID: teamID)
            let resolved = AddToChannelPickerViewModel(serverID: server.id,
                                                       teamID: teamID,
                                                       myUserID: coordinator.myUserID(for: server) ?? "",
                                                       userID: userID,
                                                       userDisplayName: userDisplayName,
                                                       service: coordinator.channelInfoService(for: server))
            model = resolved
            await resolved.load(answer: answer)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addToChannel.picker")
    }
}

/// The observing half: every read below is a `@Published` read, so the list, the selection, the
/// "already a member" sentence and the Add button all follow the model.
struct AddToChannelPickerContent: View {
    @ObservedObject var model: AddToChannelPickerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                bannerView(banner)
            }
            switch model.phase {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failureState(message)
            case .loaded:
                loaded
            }
        }
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search channels", text: $model.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("addToChannel.search")
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if model.visibleRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(model.rows.isEmpty
                         ? "You do not manage the members of any channel in this team."
                         : "No channel matches “\(model.query)”.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("addToChannel.empty")
                Spacer(minLength: 0)
            } else {
                List(model.visibleRows) { row in
                    Button {
                        Task { await model.select(row.channelID) }
                    } label: {
                        rowLabel(row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(row.subtitle)
                    .accessibilityIdentifier("addToChannel.row.\(row.channelID)")
                }
                .listStyle(.plain)
            }

            submitBar
        }
    }

    private func rowLabel(_ row: AddToChannelRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.kind.glyph)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.selectedID == row.channelID {
                Image(systemName: row.isMember == true ? "checkmark.circle.fill" : "circle.inset.filled")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            } else if row.isMember == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var submitBar: some View {
        VStack(spacing: 6) {
            if let already = model.alreadyMemberMessage {
                Text(already)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("addToChannel.alreadyMember")
            }
            Button {
                Task { await model.add() }
            } label: {
                Text("Add to channel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("addToChannel.submit")
        }
        .padding(16)
    }

    private func bannerView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                model.consumeBanner()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addToChannel.banner")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("addToChannel.error")
            Button("Try again") {
                Task { await model.load() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("addToChannel.retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
