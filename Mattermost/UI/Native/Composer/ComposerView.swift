// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_draft/post_draft.tsx (the bar: input, quick actions, send), post_input/
//        (the growing text input), send_button/send_button.tsx, quick_actions/quick_actions.tsx
//        (attach / camera / emoji), uploads/uploads.tsx (the attachment tray with progress + cancel),
//        autocomplete/autocomplete.tsx (the suggestion list above the input), typing/typing.tsx,
//        app/screens/edit_post/edit_post.tsx (the "Editing" header), thread/reply banner,
//        post_draft/archived/index.tsx + post_draft/read_only/index.tsx (the banners that replace the
//        input when posting is not possible). T4g draws those two banners: the state they state is
//        derived in ComposerPosting.swift from the channel's `delete_at` and the membership's role
//        permissions, and `send()` refuses with the same sentence.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
// upstream source copied. The SwiftUI decomposition is this repo's own (component-map.md §3).

import GameController
//
// Why `UITextView` and not `TextField(axis: .vertical)`:
//  - the autocomplete is anchored at the **caret**, and SwiftUI's text views do not expose one before
//    iOS 18 (`TextSelection`); a composer that only completes at the end of the text is a different
//    product;
//  - the markdown toolbar has to edit the *selection*, not the whole string;
//  - and a multi-line growing input with a placeholder is three lines of UIKit against a stack of
//    SwiftUI workarounds. The representable below is the only bridge, and it forwards (text, caret)
//    as one event so the two can never disagree (see `ComposerViewModel.textChanged`).

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - The text input

/// A growing multi-line input with a placeholder, reporting text *and* selection together.
struct ComposerTextView: UIViewRepresentable {
    var text: String
    var caret: Int
    var placeholder: String
    var onEdit: (String, NSRange) -> Void
    var onSelection: (NSRange) -> Void
    /// The height policy for the current text and device: 34/88 on a phone, 34/150 on a tablet or
    /// Mac window, 56/220 at accessibility sizes (see `ComposerInputHeight`). Passed in rather than
    /// read from the environment here, because the view is also built by fixtures with no Dynamic Type.
    var limits: ComposerInputHeight.Limits
    /// The measured height, reported upward. The frame is driven by this value — never by a
    /// `maxHeight` — so the field grows with its text and stops exactly at the cap.
    var onMeasure: (ComposerInputHeight.Measurement) -> Void
    /// The `-uiTestExposeComposerInputGeometry` probe, or `nil` in every other build.
    var probe: ComposerInputGeometryProbe? = nil
    /// Return sends; Shift+Return is a newline (see `ComposerReturnPolicy`).
    var onReturn: (Bool) -> Void
    /// A paste that carried files (a screenshot, a Finder copy, a PDF): the same intake as the
    /// picker — each upload goes through `ComposerViewModel.add`.
    var onPasteFiles: ([ComposerUpload]) -> Void = { _ in }
    /// A paste that could not be taken. Shown in the composer's own note line, never swallowed
    /// (upstream's `mobile.files_paste.error_title` copy; see `ComposerPaste.ErrorCopy`).
    var onPasteFailure: (String) -> Void = { _ in }
    /// Whether hardware Shift is held.
    ///
    /// A property and not a direct `GCKeyboard` read inside the delegate, because Shift+Return at the
    /// cap is one of the behaviours this card has to prove and a simulator cannot simulate the
    /// keyboard: a unit test substitutes this closure. The default is the platform's answer.
    var isShiftPressed: () -> Bool = { ComposerTextView.hardwareShiftIsPressed() }

    /// A hardware shift, where the platform can report one.
    ///
    /// `NSEvent` is not available to Mac Catalyst, so the modifier comes from GameController's view of
    /// the attached keyboard. No keyboard (or no permission to see it) reads as "not shifted", which
    /// makes Return send — the same as the on-screen key.
    static func hardwareShiftIsPressed() -> Bool {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        return input.button(forKeyCode: .leftShift)?.isPressed == true
            || input.button(forKeyCode: .rightShift)?.isPressed == true
    }

    func makeUIView(context: Context) -> ComposerInputTextView {
        // `PasteAwareTextView`, not the plain field: an image on the pasteboard has no text
        // representation, so a plain `UITextView` disables Paste and Cmd+V does nothing at all
        // (kanban t_9fe70579). Everything else about the view is the measurement/caret behaviour it
        // inherits.
        let view = PasteAwareTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        view.textContainer.lineFragmentPadding = 0
        // Not hard-off (that was the defect): the field measures itself and the scroller comes on only
        // once the text is taller than the cap. See `ComposerInputTextView.remeasure`.
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "channelComposer.input"
        view.accessibilityLabel = placeholder
        view.limits = limits
        view.onMeasure = { [weak coordinator = context.coordinator] measurement in
            guard let coordinator else { return }
            coordinator.parent.onMeasure(measurement)
        }
        // The same weak-coordinator hop as `onMeasure`: the closures read `coordinator.parent`, which
        // `updateUIView` refreshes, so a rebuilt SwiftUI value never talks to a stale parent.
        view.onPasteUploads = { [weak coordinator = context.coordinator] uploads in
            coordinator?.parent.onPasteFiles(uploads)
        }
        view.onPasteFailure = { [weak coordinator = context.coordinator] message in
            coordinator?.parent.onPasteFailure(message)
        }
        probe?.view = view
        return view
    }

    func updateUIView(_ uiView: ComposerInputTextView, context: Context) {
        context.coordinator.parent = self
        // Dynamic Type: the font has to follow the setting *before* the height is measured, or the
        // stored height belongs to the previous size class (requirement 4).
        let font = UIFont.preferredFont(forTextStyle: .body)
        if uiView.font != font { uiView.font = font }
        uiView.limits = limits
        if uiView.text != text {
            uiView.text = text
            // A programmatic edit (a suggestion, a toolbar action, a draft restore, the clear after a
            // send) carries its own caret; a keystroke does not reach this branch at all.
            let length = (text as NSString).length
            uiView.selectedRange = NSRange(location: max(0, min(caret, length)), length: 0)
        }
        uiView.accessibilityValue = text
        // Re-measure on every update: a drawer of a restored draft, a suggestion insert, a font change
        // and the clear after a send all arrive here, and each of them changes the right height.
        uiView.remeasure()
        uiView.keepCaretVisible()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.onEdit(textView.text, textView.selectedRange)
            // Requirement 3: the caret follows the text. Past the cap the field scrolls instead of
            // growing, and without this every character typed at the end would land below the visible
            // region — the everyday form of the reported defect.
            guard let view = textView as? ComposerInputTextView else { return }
            view.remeasure()
            view.keepCaretVisible()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.onSelection(textView.selectedRange)
        }

        /// Return reaches a `UITextView` as a `"\n"` insertion, not as a key press, so this is where
        /// the send/newline decision has to be made. Refusing the change keeps the text intact while
        /// the message is sent.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let action = ComposerReturnPolicy.action(isReturnKey: true,
                                                     shiftPressed: parent.isShiftPressed())
            guard action == .send else { return action == .newline }
            parent.onReturn(true)
            return false
        }
    }
}

// MARK: - The typing row

/// "X is typing…" above the input — upstream's `post_draft/typing/index.tsx`.
///
/// It observes the indicator itself rather than taking a `String?` from the pane: the row appears and
/// vanishes on its own timers, and the pane's post list must not be re-derived because somebody
/// started typing. `nil` text draws **nothing** (not an empty line), which is how upstream's
/// `StatusIndicator(visible: typing.length > 0)` behaves.
private struct TypingRow: View {
    @ObservedObject var indicator: TypingIndicator
    /// Which pane's row this is. The channel and a thread draw the same component, and both can be
    /// mounted at once on a wide layout — a single identifier would make "the row exists" true because
    /// of the *other* pane.
    let identifier: String

    var body: some View {
        if let label = indicator.label {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - The composer

/// The write surface for one channel (or one thread): input, toolbar, attachments, autocomplete, send.
struct ComposerView: View {
    @ObservedObject var model: ComposerViewModel
    /// The pane's custom-emoji catalogue, so `:` completes the names the server owns.
    var emoji: EmojiCatalogue?
    /// T37: the picker's "recently used" row (one store per server and user, shared with the list).
    var recents: EmojiRecentsStore? = nil
    /// T4f: the pane's typing row ("X is typing…"), drawn above the input exactly where upstream's
    /// `post_draft/typing/index.tsx` sits inside `PostDraft`. `nil` for a host with no pane (a bare
    /// SwiftUI preview, the composer's own unit fixtures), which draws no row at all.
    var typing: TypingIndicator? = nil
    /// T4f: which pane's row this is (see `TypingRow.identifier`). Defaults to the channel's, because
    /// that is the pane every other caller is.
    var typingRowIdentifier: String = "channelComposer.typing"

    /// True while the input has keyboard focus; the suggested list is only useful then.
    @State private var isFocused = false
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isAttachMenuPresented = false
    /// T37: the emoji picker, opened from the toolbar.
    @State private var isEmojiPickerPresented = false
    /// The last selection the input reported, used to place a toolbar edit.
    @State private var selection = NSRange(location: 0, length: 0)
    /// The input's measured height (kanban t_fbc576a2). A frame that caps a text view is not a
    /// growing field: past the cap the view had nowhere to draw and its scroller was off, so the text
    /// was clipped and the caret walked off-screen. The height now comes *from* the measurement
    /// (`ComposerInputTextView.remeasure`), clamped to `ComposerInputHeight.Limits`, and the frame
    /// follows it exactly. The initial value is the phone floor; the first layout pass replaces it
    /// with the measurement for the device, the text size and the text actually present.
    @State private var inputHeight = ComposerInputHeight.Limits.phone.minimum
    /// The `-uiTestExposeComposerInputGeometry` probe: what the input measured, published as an
    /// accessibility value for the live UI test. Unused (and unread) without the launch argument.
    @StateObject private var inputProbe = ComposerInputGeometryProbe()

    /// The debounce-free view of the model's text, so the preview and the toolbar can read it.
    private var message: String { model.text }

    /// T45: at an accessibility text size the control cluster reflows above the
    /// input. Measured at AX3 on an iPhone 16 Pro: four scaled glyph buttons took
    /// ~160 pt of a 402 pt row, leaving the input about 60 pt wide — the word
    /// "Message" hyphenated to "Mes-sage" and the placeholder was clipped by the
    /// field's min-height. Reflow rather than shrink: the glyphs are what a
    /// low-vision reader needs to hit.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if model.posting.canPost {
                composerBody
            } else {
                postingBanner
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.bar)
        // `.contain` first, identifier second: an accessibility identifier on a SwiftUI container
        // *overwrites* its descendants' identifiers, so without this the Send button and the text
        // view both reported `channelComposer` and no part of the composer could be addressed
        // (found by the live UI suite, which could not find `channelComposer.input` at all).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channelComposer")
        .task {
            await model.restoreDraftIfNeeded()
            // T4g: the write surface's state, asked once per pane appearance. The draft restore above
            // already ran, so the words a reader left here are in the model even if the banner is
            // about to replace the input (they are simply not sendable until the channel is restored).
            model.refreshPostingState()
            attachUITestFileIfRequested()
        }
        .onChange(of: model.mode) { _, _ in
            selection = NSRange(location: 0, length: (model.text as NSString).length)
        }
        .photosPicker(isPresented: $isPhotoPickerPresented,
                      selection: $pickerItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item: item) }
        }
        .fileImporter(isPresented: $isFileImporterPresented,
                      allowedContentTypes: [.data, .image, .audio, .movie, .pdf],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                load(url: url)
            }
        }
    }

    /// Everything the reader types with: input, controls, autocomplete, attachments, banners.
    private var composerBody: some View {
        VStack(spacing: 6) {
            if let note = model.statusNote { statusLine(note) }
            if case .failed(let reason) = model.phase { failureBanner(reason) }
            if model.mode != .newPost { modeBanner }
            if !model.suggestions.isEmpty { suggestionList }
            if model.isPreviewing { preview }
            if !model.attachments.isEmpty { attachmentTray }
            if let typing { TypingRow(indicator: typing, identifier: typingRowIdentifier) }
            inputRow
        }
    }

    // MARK: Input

    private var inputRow: some View {
        VStack(spacing: 4) {
            if typeSize.isAccessibilitySize {
                // Reflow: input first, controls below it. See `typeSize`.
                VStack(alignment: .leading, spacing: 6) {
                    inputField
                    HStack(spacing: 10) {
                        attachButton
                        emojiButton
                        if model.mode == .newPost { toolbarMenu }
                        Spacer(minLength: 0)
                        sendButton
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    attachButton
                    emojiButton
                    inputField
                    if model.mode == .newPost { toolbarMenu }
                    sendButton
                }
            }
            if !message.isEmpty || model.mode != .newPost { markdownToolbar }
        }
    }

    /// The text field and its placeholder, sized for the current text size.
    ///
    /// The height grows with Dynamic Type rather than staying at 34 pt: at AX3 a
    /// `body` line is ~40 pt tall, so a fixed 34 pt field clipped the first line
    /// and the placeholder with it (measured in the AX3 capture).
    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            if message.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ComposerTextView(text: message,
                             caret: model.caret,
                             placeholder: placeholder,
                             onEdit: { text, range in
                                 selection = range
                                 model.textChanged(text, caret: NSMaxRange(range))
                             },
                             onSelection: { range in
                                 selection = range
                                 model.caretMoved(to: NSMaxRange(range))
                             },
                             limits: ComposerInputHeight.limits(for: typeSize),
                             onMeasure: { measurement in
                                 // Only a *changed* height is written: re-measuring with the same
                                 // answer must not cost a SwiftUI render (a layout pass measures).
                                 if inputHeight != measurement.height {
                                     inputHeight = measurement.height
                                 }
                             },
                             probe: ComposerInputDiagnostics.isEnabled ? inputProbe : nil,
                             onReturn: { _ in
                                 // Same entry point as the send button: one send path, so a
                                 // Return and a click cannot disagree about draft, uploads or
                                 // the editing mode.
                                 guard model.canSend else { return }
                                 Task { await model.send() }
                             },
                             onPasteFiles: { uploads in
                                 // The picker's own intake (ComposerView.load(item:)/load(url:)),
                                 // one call per file: `add` appends the chip and starts the upload,
                                 // and the send posts the uploaded ids. A pasted file gets the same
                                 // progress, retry and `.failed` state as a picked one — there is no
                                 // second upload path (kanban t_9fe70579).
                                 for upload in uploads { model.add(upload) }
                             },
                             onPasteFailure: { message in
                                 // The composer's existing error surface: the note line above the
                                 // input. Upstream shows an Alert; see the build note's divergence
                                 // section for why this client does not.
                                 model.pasteDidFail(message)
                             })
                // The height is the measurement, not a window it is allowed to grow into. The
                // previous `minHeight/maxHeight` frame is what clipped a message past the cap: the
                // text view kept drawing at its frame and had no scroller to reach the rest.
                .frame(height: inputHeight)
                .overlay(alignment: .topTrailing) {
                    if ComposerInputDiagnostics.isEnabled {
                        ComposerInputGeometrySeam(probe: inputProbe)
                    }
                }
        }
        .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil,
               alignment: .leading)
    }

    private var placeholder: String {
        switch model.mode {
        case .editing: return "Edit message"
        case .reply: return "Reply to the thread…"
        case .newPost: return "Message"
        }
    }

    /// T37: the emoji picker entry point. A toolbar button rather than a long-press: the composer's
    /// `:` trigger serves people who type shortcodes, the picker serves everyone else.
    private var emojiButton: some View {
        Button {
            isEmojiPickerPresented = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 21))
                .foregroundStyle(model.mode.isEditing ? .tertiary : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add emoji")
        .accessibilityIdentifier("channelComposer.emoji")
        .sheet(isPresented: $isEmojiPickerPresented) {
            EmojiPickerView(
                model: EmojiPickerViewModel(mode: .composer,
                                            catalogue: emoji,
                                            recents: recents,
                                            onPick: { item in
                                                isEmojiPickerPresented = false
                                                // A custom emoji has no character: the message carries
                                                // its shortcode, which the server renders.
                                                let insert = item.character ?? ":\(item.name):"
                                                recents?.record(item.name)
                                                _ = model.insertEmoji(insert)
                                            }),
                emoji: emoji)
        }
    }

    private var attachButton: some View {
        Button {
            isAttachMenuPresented = true
        } label: {
            Image(systemName: "plus.circle")
                .scaledSymbol(22)
                .foregroundStyle(model.mode.isEditing ? .tertiary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(model.mode.isEditing)
        .accessibilityLabel("Add an attachment")
        .accessibilityIdentifier("channelComposer.attach")
        .confirmationDialog("Add an attachment", isPresented: $isAttachMenuPresented) {
            Button("Photo library") { isPhotoPickerPresented = true }
            Button("Choose a file") { isFileImporterPresented = true }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sendButton: some View {
        Button {
            Task { await model.send() }
        } label: {
            if model.phase == .sending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else if model.mode.isEditing {
                Image(systemName: "checkmark.circle.fill")
                    .scaledSymbol(26)
                    .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .scaledSymbol(26)
                    .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel(model.mode.isEditing ? "Save" : "Send")
        .accessibilityIdentifier("channelComposer.send")
    }

    private var toolbarMenu: some View {
        Menu {
            Button {
                model.togglePreview()
            } label: {
                Label(model.isPreviewing ? "Hide preview" : "Preview",
                      systemImage: model.isPreviewing ? "eye.slash" : "eye")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .scaledSymbol(22)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("channelComposer.menu")
        .accessibilityLabel("Formatting and preview")
    }

    /// The formatting row. Each button edits the *selection*, which the input reported last; the
    /// returned range is written back so the words stay selected (or the caret lands between a new
    /// marker pair).
    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(ComposerMarkdownAction.allCases, id: \.rawValue) { action in
                    Button {
                        selection = model.applyMarkdown(action, selection: selection)
                    } label: {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier("channelComposer.format.\(action.rawValue)")
                }
                Divider().frame(height: 14)
                Button {
                    model.togglePreview()
                } label: {
                    Image(systemName: model.isPreviewing ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(model.isPreviewing ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPreviewing ? "Hide preview" : "Show preview")
                .accessibilityIdentifier("channelComposer.preview")
            }
            .padding(.vertical, 2)
        }
        .frame(height: 20)
    }

    // MARK: Autocomplete

    /// The glyph for a suggestion with no emoji character. A command is a `/`, a channel a `#`, and
    /// a person an avatar.
    private func iconName(for kind: ComposerSuggestion.Kind) -> String {
        switch kind {
        case .channel: return "number"
        case .slash: return "slash.circle"
        case .user, .specialMention, .emoji: return "person.crop.circle"
        }
    }

    /// What VoiceOver reads for a row: the primary line, the argument grammar when there is one, and
    /// the description — the same order the row draws them in.
    private func accessibilityLabel(for suggestion: ComposerSuggestion) -> String {
        var parts = [suggestion.label]
        if let hint = suggestion.hint, !hint.isEmpty { parts.append(hint) }
        if !suggestion.detail.isEmpty { parts.append(suggestion.detail) }
        return parts.joined(separator: " ")
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A bare `@` lists this channel's members, and the list scrolls: the caption belongs
                // above it, where it is read before the rows, instead of under a band it would push
                // off the first screen.
                if model.activeTrigger?.term.isEmpty == true, !model.suggestions.isEmpty {
                    Text("Type to narrow this list")
                        .font(.scaled(12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .accessibilityIdentifier("composerSuggestions.hint")
                }
                ForEach(ComposerSuggestionList.rows(model.suggestions)) { row in
                    switch row {
                    case .header(_, let title):
                        // The band's heading. It is not a button: VoiceOver reads it as a header, and
                        // the rows under it are the choices (kanban t_03f2dbfd).
                        Text(title)
                            .font(.scaled(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("composerSection.\(row.id)")
                    case .suggestion(let suggestion):
                        suggestionRow(suggestion)
                        Divider().padding(.leading, 10)
                    }
                }
                if let note = model.suggestionNote {
                    // Why the list is thin, when it is: a failed request used to look exactly like a
                    // term nobody matches.
                    Text(note)
                        .font(.scaled(12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .accessibilityIdentifier("composerSuggestions.note")
                }
            }
        }
        .frame(maxHeight: 200)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        // `.contain` so each row keeps its own `composerSuggestion.<kind>-<value>` identifier: a bare
        // identifier on this container would relabel every row `composerSuggestions`.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composerSuggestions")
    }

    /// One choice: the glyph or icon, the label, a command's argument grammar, and the detail line.
    private func suggestionRow(_ suggestion: ComposerSuggestion) -> some View {
        Button {
            if let caret = model.apply(suggestion) {
                selection = NSRange(location: caret, length: 0)
            }
        } label: {
            HStack(spacing: 8) {
                if let glyph = suggestion.glyph {
                    Text(glyph).font(.system(size: 15))
                } else {
                    Image(systemName: iconName(for: suggestion.kind))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        // Decorative: the row is a button with its own label. Unhidden,
                        // VoiceOver announces "number, Town Square, #town-square" — the
                        // symbol name leaking into the reading — and every suggestion
                        // adds another element to the accessibility snapshot the UI
                        // test's serialiser logs (T8d).
                        .accessibilityHidden(true)
                }
                Text(suggestion.label)
                    .font(.scaled(15))
                    .mmLineLimit(1)
                // The command's argument grammar, right after its trigger: upstream's
                // row reads "/invite @[username]... ~[channel]..." and nothing else
                // says what to type next.
                if let hint = suggestion.hint, !hint.isEmpty {
                    Text(hint)
                        .font(.scaled(13))
                        .foregroundStyle(.secondary)
                        .mmLineLimit(1)
                        .accessibilityIdentifier("composerSuggestion.\(suggestion.id).hint")
                }
                Text(suggestion.detail)
                    .font(.scaled(12))
                    .foregroundStyle(.secondary)
                    .mmLineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composerSuggestion.\(suggestion.id)")
        .accessibilityLabel(accessibilityLabel(for: suggestion))
    }

    // MARK: Banners

    /// The replacement for the whole write surface when posting is impossible — upstream's
    /// `post_draft/archived/index.tsx` and `post_draft/read_only/index.tsx`.
    ///
    /// Drawn *instead of* the input, the controls and the send button (upstream returns the banner
    /// from `PostDraft` before `DraftHandler` is built), so there is no control here that could only
    /// fail. The copy is the model's (`ComposerPostingState.message`), which is also the sentence
    /// `send()` refuses with — one string, so the banner and the refusal cannot disagree.
    ///
    /// Two deliberate differences from upstream, both about affordances this shell already owns:
    ///  * the archived banner has **no "Close Channel" button**: upstream's is a *navigation* device
    ///    for a pushed screen, and this pane's header already carries Back, so a second control would
    ///    only be another way to do one thing;
    ///  * the copy is drawn without upstream's markdown emphasis (`**archived channel**`), because a
    ///    plain `Text` would otherwise be read out with the asterisks by VoiceOver.
    private var postingBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: model.posting.glyph)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.posting.message)
                .font(.scaled(15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.posting.message)
        .accessibilityIdentifier(model.posting.identifier)
    }

    private var modeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: model.mode.isEditing ? "pencil" : "arrowshape.turn.up.left")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(model.mode.isEditing ? "Editing message" : "Replying to \(model.replyTarget ?? "thread")")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .mmLineLimit(1)
            Spacer(minLength: 0)
            // A thread composer has no "leave reply mode" that stays in the thread — its Cancel could
            // only mean `.newPost`, i.e. a channel post while the pane reads "Replying to …"
            // (t_56159748). It is offered only where it can go *back*: out of an edit.
            if !model.isThreadComposer || model.mode.isEditing {
                Button("Cancel") {
                    Task { await model.cancelMode() }
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .accessibilityIdentifier("channelComposer.cancelMode")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.mode.isEditing ? "channelComposer.editingBanner"
                                                      : "channelComposer.replyBanner")
    }

    private func failureBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("channelComposer.error")
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await model.retry() }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .accessibilityIdentifier("channelComposer.retry")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channelComposer.failure")
    }

    private func statusLine(_ note: String) -> some View {
        Text(note)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .accessibilityIdentifier("channelComposer.status")
    }

    // MARK: Preview

    private var preview: some View {
        ScrollView {
            MarkdownView(blocks: MarkdownParser().parse(message),
                         identifierPrefix: "channelComposer.preview",
                         emoji: emoji)
                .padding(10)
        }
        .frame(maxHeight: 200)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        // The pane is `previewPane`, not `preview`: the toolbar's toggle button is
        // `channelComposer.preview`, and two elements sharing one identifier make a UI query
        // ambiguous. `.contain` keeps the blocks' own `…preview.block<n>` identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channelComposer.previewPane")
    }

    // MARK: Attachments

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 62)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channelComposer.attachments")
    }

    private func attachmentChip(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.scaled(12, weight: .medium))
                    .mmLineLimit(1)
                switch attachment.state {
                case .uploaded:
                    Text(attachment.sizeLabel)
                        .font(.scaled(10))
                        .foregroundStyle(.secondary)
                case .uploading(let progress):
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                        .accessibilityValue("\(Int(progress * 100))")
                case .queued:
                    Text("Waiting…")
                        .font(.scaled(10))
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .font(.scaled(10))
                        .foregroundStyle(.orange)
                        .mmLineLimit(1)
                }
            }
            if case .failed = attachment.state {
                Button {
                    model.retryUpload(id: attachment.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry upload of \(attachment.filename)")
                .accessibilityIdentifier("channelComposer.attachment.\(attachment.filename).retry")
            }
            Button {
                model.removeAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
            .accessibilityIdentifier("channelComposer.attachment.\(attachment.filename).remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 50)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channelComposer.attachment.\(attachment.filename)")
        // The upload's state as a value, so a UI test can watch a real upload finish instead of
        // inferring it from a progress bar's disappearance.
        .accessibilityValue(Self.stateValue(attachment.state))
    }

    /// `queued` / `uploading 42%` / `uploaded <fileID>` / `failed <reason>`.
    static func stateValue(_ state: ComposerAttachment.State) -> String {
        switch state {
        case .queued: return "queued"
        case .uploading(let progress): return "uploading \(Int((progress * 100).rounded()))%"
        case .uploaded(let fileID): return "uploaded \(fileID)"
        case .failed(let reason): return "failed \(reason)"
        }
    }

    // MARK: Picking

    private func load(item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let mime = type?.preferredMIMEType ?? "image/jpeg"
        let name = "photo-\(Int(Date().timeIntervalSince1970)).\(ext)"
        model.add(ComposerUpload(filename: name, mimeType: mime, data: data))
    }

    private func load(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        model.add(ComposerUpload(filename: url.lastPathComponent,
                                 mimeType: MMMultipart.mimeType(forFilename: url.lastPathComponent),
                                 data: data))
    }

    /// `-uiTestAttachFixtureBase64 <filename> <base64>`: XCUITest cannot drive the system photo/file
    /// pickers, so the upload path is exercised by handing the composer a file the test wrote.
    ///
    /// Base64 rather than a path because the app is sandboxed: a simulator app cannot read the
    /// host's `/tmp`, so a path argument would be a seam that only works on a machine where the test
    /// happened to write into the app container. Only the *pick* is simulated — the upload, the
    /// progress, the send, the file on the server and the row are production code.
    private func attachUITestFileIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiTestAttachFixtureBase64"),
              args.indices.contains(index + 2) else { return }
        let name = args[index + 1]
        guard let data = Data(base64Encoded: args[index + 2]), !data.isEmpty else { return }
        model.add(ComposerUpload(filename: name,
                                 mimeType: MMMultipart.mimeType(forFilename: name),
                                 data: data))
        #endif
    }
}
