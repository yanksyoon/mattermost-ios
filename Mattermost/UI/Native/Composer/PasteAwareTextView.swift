// The text view that can take a pasted file.
//
// `UITextView`'s own `paste:` only inserts text. A screenshot on the pasteboard has no text
// representation, and the menu item is not even enabled, so Cmd+V did nothing at all (kanban
// t_9fe70579). Upstream does not have the problem because its input is not a plain field:
// `@mattermost/react-native-paste-input@2.0.1` (`671378e2`, MIT) swizzles `paste:` and
// `canPerformAction:withSender:` onto the React Native TextInput's class
// (`ios/PasteInputModule.mm:325-386`). This subclass is the same seam, written as a subclass rather
// than runtime swizzling — same methods, same order of checks:
//
//   1. the MDM gate, if it is ever set, refuses the whole clipboard gesture (upstream :501-511
//      refuses cut/copy/paste when `managedConfig.copyAndPasteProtection === 'true'`);
//   2. the Paste item is *enabled* whenever the pasteboard carries anything that is not text, even
//      with no text on it (upstream :514-521 enables it for any content at all);
//   3. `paste:` takes the files through `ComposerPaste`, and runs the system paste as well when the
//      pasteboard holds text that is not a representation of those files — so a text-only paste is
//      bit-for-bit the behaviour it had before, normalisation included, and an image paste never
//      silently drops a caption that was copied with it.
//
// Catalyst: Cmd+V and the Edit > Paste menu item both arrive here as `paste:`; the menu's enabled
// state is this class's `canPerformAction`. The snapshot behind both reads `itemProviders` as well as
// `UIPasteboard.images`/`.urls`, because a macOS-backed pasteboard resolves its types lazily.

import UIKit

final class PasteAwareTextView: ComposerInputTextView {

    /// Where a paste is read from. Production reads `UIPasteboard.general`; a unit test installs a
    /// stub, because a test may not depend on the host's real clipboard.
    var pasteboard: ComposerPasteboardSource = SystemPasteboard()

    /// Whether the clipboard gesture is allowed at all — the one place `ComposerPastePolicy` is read
    /// (requirement T8). A closure so a test can pin either answer without touching global state.
    var pasteAllowed: () -> Bool = { !ComposerPastePolicy.copyAndPasteProtection }

    /// The files a paste produced, in pasteboard order. The composer adds each one through
    /// `ComposerViewModel.add` — the picker's own intake, so a pasted file gets the same chip, the
    /// same progress, the same retry and the same `.failed` state a picked one gets.
    var onPasteUploads: (([ComposerUpload]) -> Void)?

    /// A paste that could not be taken, as the sentence to show. Nothing is silently dropped.
    var onPasteFailure: ((String) -> Void)?

    /// The in-flight conversion, so a test can await what the gesture started instead of polling.
    /// The composer does not read it; the work is fire-and-forget there, exactly like a picker's.
    private(set) var pasteTask: Task<Void, Never>?

    // MARK: The menu item

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let protected = action == #selector(paste(_:))
            || action == #selector(copy(_:))
            || action == #selector(cut(_:))
        if protected, !pasteAllowed() { return false }
        // An image or a file URL has no text representation, so the base class answers NO: without
        // this the Paste item stays greyed out and the shortcut does nothing (the defect). The
        // question is asked of the pasteboard's *metadata* only — loading item data here would block
        // the main thread on the system's paste-approval prompt.
        if action == #selector(paste(_:)), pasteboard.declaresAttachableContent() {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: The gesture

    override func paste(_ sender: Any?) {
        guard pasteAllowed() else {
            onPasteFailure?(ComposerPaste.ErrorCopy.disabled)
            return
        }

        let snapshot = pasteboard.snapshot()

        guard ComposerPaste.hasAttachableContent(snapshot) else {
            // Text, a link, rich text — everything the field has always pasted. The text view inserts
            // it itself, which is what keeps the composer's normalisation and trigger parsing on the
            // one path they already own (requirement 5).
            super.paste(sender)
            return
        }

        // Text *as well as* files: insert it first, at the caret, through the same system path. The
        // files are read asynchronously; the words do not wait for a decode.
        if ComposerPaste.textToInsert(snapshot) != nil {
            super.paste(sender)
        }

        pasteTask = Task { [weak self] in
            let outcome = await ComposerPaste.read(snapshot)
            guard let self else { return }
            if !outcome.uploads.isEmpty {
                self.onPasteUploads?(outcome.uploads)
            }
            for failure in outcome.failures {
                self.onPasteFailure?(failure)
            }
        }
    }
}
