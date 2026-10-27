// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_draft/post_draft.tsx (the bar: input, quick actions, send), post_input/
//        (the growing text input), send_button/send_button.tsx, quick_actions/quick_actions.tsx
//        (attach / camera / emoji), uploads/uploads.tsx (the attachment tray with progress + cancel),
//        autocomplete/autocomplete.tsx (the suggestion list above the input), typing/typing.tsx,
//        app/screens/edit_post/edit_post.tsx (the "Editing" header), thread/reply banner.
//        Read and **not** drawn: archived/ + read_only/ (the banners that replace the input when
//        posting is not possible) — this build has no archived-channel or read-only-membership state,
//        so the input stays and the server's refusal reaches the failure banner instead
//        (docs/t35-build-note.md §5).
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
    /// Return sends; Shift+Return is a newline (see `ComposerReturnPolicy`).
    var onReturn: (Bool) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "channelComposer.input"
        view.accessibilityLabel = placeholder
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
            // A programmatic edit (a suggestion, a toolbar action, a draft restore) carries its own
            // caret; a keystroke does not reach this branch at all.
            let length = (text as NSString).length
            uiView.selectedRange = NSRange(location: max(0, min(caret, length)), length: 0)
        }
        uiView.accessibilityValue = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.onEdit(textView.text, textView.selectedRange)
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
                                                     shiftPressed: Self.shiftIsPressed)
            guard action == .send else { return action == .newline }
            parent.onReturn(true)
            return false
        }

        /// A hardware shift, where the platform can report one.
        ///
        /// `NSEvent` is not available to Mac Catalyst, so the modifier comes from GameController's
        /// view of the attached keyboard. No keyboard (or no permission to see it) reads as "not
        /// shifted", which makes Return send — the same as the on-screen key.
        static var shiftIsPressed: Bool {
            guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
            return input.button(forKeyCode: .leftShift)?.isPressed == true
                || input.button(forKeyCode: .rightShift)?.isPressed == true
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

    /// The debounce-free view of the model's text, so the preview and the toolbar can read it.
    private var message: String { model.text }

    var body: some View {
        VStack(spacing: 6) {
            if let note = model.statusNote { statusLine(note) }
            if case .failed(let reason) = model.phase { failureBanner(reason) }
            if model.mode != .newPost { modeBanner }
            if !model.suggestions.isEmpty { suggestionList }
            if model.isPreviewing { preview }
            if !model.attachments.isEmpty { attachmentTray }
            inputRow
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

    // MARK: Input

    private var inputRow: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                attachButton
                emojiButton
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
                                     onReturn: { _ in
                                         // Same entry point as the send button: one send path, so a
                                         // Return and a click cannot disagree about draft, uploads or
                                         // the editing mode.
                                         guard model.canSend else { return }
                                         Task { await model.send() }
                                     })
                        .frame(minHeight: 34, maxHeight: 140)
                }
                if model.mode == .newPost { toolbarMenu }
                sendButton
            }
            if !message.isEmpty || model.mode != .newPost { markdownToolbar }
        }
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
                .font(.system(size: 22))
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
                    .font(.system(size: 26))
                    .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
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
                .font(.system(size: 22))
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

    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.suggestions.prefix(8)) { suggestion in
                    Button {
                        if let caret = model.apply(suggestion) {
                            selection = NSRange(location: caret, length: 0)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if let glyph = suggestion.glyph {
                                Text(glyph).font(.system(size: 15))
                            } else {
                                Image(systemName: suggestion.kind == .channel ? "number" : "person.crop.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            Text(suggestion.label)
                                .font(.system(size: 15))
                                .lineLimit(1)
                            Text(suggestion.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("composerSuggestion.\(suggestion.id)")
                    .accessibilityLabel("\(suggestion.label) \(suggestion.detail)")
                    Divider().padding(.leading, 10)
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

    // MARK: Banners

    private var modeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: model.mode.isEditing ? "pencil" : "arrowshape.turn.up.left")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(model.mode.isEditing ? "Editing message" : "Replying to \(model.replyTarget ?? "thread")")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel") {
                Task { await model.cancelMode() }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            .accessibilityIdentifier("channelComposer.cancelMode")
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                switch attachment.state {
                case .uploaded:
                    Text(attachment.sizeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .uploading(let progress):
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                        .accessibilityValue("\(Int(progress * 100))")
                case .queued:
                    Text("Waiting…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
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
