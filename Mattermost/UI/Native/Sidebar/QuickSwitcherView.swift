// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/find_channels/index.tsx (a search field over a result list, results opening the
//        channel), find_channels/filtered_list/ (name matching + the "nothing found" state),
//        find_channels/quick_options/, and the desktop/web quick switcher (ctrl/cmd-K) it mirrors.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied.

import SwiftUI

/// The quick switcher: type, pick a channel or DM, land in it.
///
/// It is a sheet rather than a tab because it is a *gesture* ("take me to…"), not a place: it opens
/// over the sidebar, navigates through the same `NativeNavigation` funnel a row tap uses, and closes.
/// `⌘K` on a hardware keyboard opens it from the sidebar (see `NativeChannelSidebarContent`).
///
/// The search field is a plain `TextField` rather than `.searchable`: the deployment target predates
/// `.searchFocused`, and a switcher whose field is not focused when it opens is a menu, not a
/// switcher. It also gives the field a stable identifier for a UI test.
struct QuickSwitcherView: View {
    @ObservedObject var model: ChannelListViewModel
    let onSelect: (ChannelSidebarEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private var results: [ChannelSidebarEntry] { model.searchResults(for: query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                resultList
            }
            .navigationTitle("Jump to")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("channelSidebar.quickSwitcher.cancel")
                }
            }
        }
        .task {
            // Focus as soon as the sheet settles; the delay is one runloop, not a guess at how long a
            // network takes (there is no network in this view).
            try? await Task.sleep(nanoseconds: 120_000_000)
            isFieldFocused = true
        }
        .accessibilityIdentifier("channelSidebar.quickSwitcher.sheet")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search channels and people", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isFieldFocused)
                .accessibilityIdentifier("channelSidebar.quickSwitcher.field")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var resultList: some View {
        List {
            if results.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "No channels loaded yet"
                             : "No channel matches “\(query)”")
                            .font(.subheadline.weight(.semibold))
                        Text("Try a channel name (#), a person (@), or a few letters in the middle.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("channelSidebar.quickSwitcher.empty")
                }
            } else {
                Section {
                    ForEach(results) { entry in
                        Button {
                            onSelect(entry)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.iconSymbolName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.displayName)
                                        .fontWeight(entry.showsUnreadEmphasis ? .bold : .regular)
                                        .lineLimit(1)
                                    if entry.kind.isDirect {
                                        Text(entry.kind.accessibilityName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                                if let text = entry.badgeText {
                                    Text(text)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.red, in: Capsule())
                                        .accessibilityHidden(true)
                                }
                            }
                            // A `.plain` button hit-tests its **label's content shape**, not the row
                            // its frame fills: without this the space after the Spacer is a dead
                            // zone, so a tap on the right half of the row (which VoiceOver and
                            // XCUITest both report as part of the row) does nothing at all.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("channelSidebar.quickSwitcher.result.\(entry.id)")
                        .accessibilityLabel(entry.displayName)
                        .accessibilityValue(entry.accessibilityValue)
                    }
                } header: {
                    Text("Channels and people")
                }
            }
        }
        .listStyle(.plain)
    }
}
