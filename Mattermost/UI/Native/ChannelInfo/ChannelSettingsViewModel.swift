// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/create_or_edit_channel/create_or_edit_channel.tsx (the edit path: the three
//        fields, `validateDisplayName`, the "nothing changed" rule, and the `{display_name, purpose,
//        header}` patch), app/screens/create_or_edit_channel/channel_info_form.tsx (the field order and
//        the character counters), app/screens/channel_settings/archive/archive.tsx (archive and
//        unarchive with their confirmations), app/screens/channel_settings/convert_private.tsx
//        (deliberately **not** ported — see below).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied.
//
// Scope note: the card names *rename, purpose, header, archive/unarchive*. Upstream's channel settings
// screen also offers "Convert to private" and (for shared channels) the translation settings; those are
// **not** in T40's scope and are not drawn. A row that does nothing is worse than a row that is absent.
//
// The form owns no writes: it holds the draft and answers "may this be saved", and the screen calls
// `ChannelInfoViewModel.save(_:)`, where the permission gate already lives.

import Foundation
import Combine

@MainActor
final class ChannelSettingsViewModel: ObservableObject {

    /// The channel as it was when the form opened. The patch is computed **against this**, so a server
    /// that normalises a value (or a socket that renames the channel while the form is open) cannot make
    /// the form send a field the reader never touched.
    let original: MMChannel
    let kind: ChannelInfoKind

    @Published var draft: ChannelPatchDraft
    /// A save failure, in the reader's words.
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSaving = false
    /// Set when the server accepted the save (the screen then closes).
    @Published private(set) var didSave = false

    init(channel: MMChannel) {
        self.original = channel
        self.kind = ChannelInfoKind(raw: channel.type)
        self.draft = ChannelPatchDraft(channel: channel)
    }

    /// The validation sentence, or `nil` when the draft may be sent.
    var validationMessage: String? { draft.validation(for: kind) }

    /// Upstream disables Save until something changed; so does this.
    var canSave: Bool {
        !isSaving && validationMessage == nil && draft.isDirty(comparedTo: original, kind: kind)
    }

    /// The body the screen hands to `ChannelInfoViewModel.save`, or `nil` when nothing changed.
    var patch: MMChannelPatch? {
        draft.patch(comparedTo: original, kind: kind)
    }

    /// Whether the name field is editable at all: a DM/GM has no display name (it is derived from its
    /// members), so only the header is offered for those.
    var showsNameAndPurpose: Bool { !kind.isDirectOrGroup }

    /// Character counters, drawn only when the field is close to its limit (upstream's counter appears at
    /// 80% — a counter on every field is noise).
    func nameCounter(_ text: String) -> String? {
        counter(text, limit: ChannelPatchDraft.maxDisplayNameLength)
    }

    func purposeCounter(_ text: String) -> String? {
        counter(text, limit: ChannelPatchDraft.maxPurposeLength)
    }

    func headerCounter(_ text: String) -> String? {
        counter(text, limit: ChannelPatchDraft.maxHeaderLength)
    }

    private func counter(_ text: String, limit: Int) -> String? {
        guard text.count >= Int(Double(limit) * 0.8) else { return nil }
        return "\(text.count)/\(limit)"
    }

    // MARK: Write state

    /// Called by the screen around `ChannelInfoViewModel.save(_:)`, so the form's own busy state and the
    /// info screen's agree.
    func beginSaving() {
        isSaving = true
        errorMessage = nil
    }

    func finishSaving(succeeded: Bool, message: String?) {
        isSaving = false
        didSave = succeeded
        errorMessage = succeeded ? nil : message
    }
}
