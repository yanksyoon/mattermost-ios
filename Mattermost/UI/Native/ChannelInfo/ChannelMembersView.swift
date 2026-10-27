// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/manage_channel_members/manage_channel_members.tsx (the search field, the paged
//        list, `sortUsers`, the per-row remove path with its confirmation),
//        app/components/user_list_row/* (the avatar, the name, the presence dot).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// The rows are drawn from `ChannelInfoViewModel.memberRows`, which is derived purely
// (`ChannelMemberDerivation.rows`) and sorted the way upstream sorts (`sortUsers`: display name,
// locale-aware, username as the tiebreak). Removal is offered only when `canManageMembers`, and the
// write is refused again inside the view model — the two checks exist because hiding a control is a UI
// state while refusing a write is the guarantee.

import SwiftUI

struct ChannelMembersView: View {
    @ObservedObject var model: ChannelInfoViewModel
    let canManage: Bool

    @State private var pendingRemoval: ChannelMemberRow?

    var body: some View {
        List {
            if let banner = model.banner {
                Section {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("channelMembers.banner")
                }
            }
            Section {
                ForEach(model.visibleMemberRows) { row in
                    memberRow(row)
                        .accessibilityIdentifier("channelMemberRow.\(row.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManage, !row.isMe {
                                Button(role: .destructive) {
                                    pendingRemoval = row
                                } label: {
                                    Label("Remove", systemImage: "person.badge.minus")
                                }
                                .accessibilityIdentifier("channelMember.remove.\(row.id)")
                            }
                        }
                }
                if model.isLoadingMoreMembers {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } footer: {
                if !model.memberCountText.isEmpty {
                    Text(model.memberCountText)
                        .accessibilityIdentifier("channelMembers.count")
                }
            }
        }
        .searchable(text: $model.memberSearch, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search members")
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // The list is a page at a time; the info screen already asked for the first one, so this
            // only fires when the reader opens the list before it finished.
            if model.memberRows.isEmpty {
                Task { await model.load() }
            }
        }
        .confirmationDialog("Remove \(pendingRemoval?.displayName ?? "this member")?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let row = pendingRemoval else { return }
                pendingRemoval = nil
                Task { await model.removeMember(userID: row.id) }
            }
            .accessibilityIdentifier("channelMember.remove.confirm")
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("They will be removed from this channel. They can be added again later.")
        }
        .accessibilityIdentifier("channelMembers.list")
    }

    @ViewBuilder
    private func memberRow(_ row: ChannelMemberRow) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                Text(row.initials)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                // The server's picture, when this account has one (the initials stay underneath).
                AvatarPicture(userID: row.id, size: 32)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.body)
                    if row.isMe {
                        Text("You")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !row.username.isEmpty {
                    Text("@\(row.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !row.roleLabel.isEmpty {
                Text(row.roleLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Circle()
                .fill(presenceColor(row.status))
                .frame(width: 8, height: 8)
                .accessibilityLabel(row.statusLabel)
        }
        .padding(.vertical, 2)
    }

    private func presenceColor(_ status: String) -> Color {
        switch status {
        case "online": return .green
        case "away": return .yellow
        case "dnd": return .red
        case "offline": return Color.secondary.opacity(0.35)
        default: return Color.secondary.opacity(0.15)
        }
    }
}
