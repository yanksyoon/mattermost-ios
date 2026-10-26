// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_list/post/body/reactions/reaction.tsx (one pill: emoji, count, the
//        `highlight` state for "you reacted", tap = toggle, long press = who reacted),
//        reactions.tsx (the pill row, `+` affordance opens the picker).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14; no
// upstream source copied. The SwiftUI decomposition is this repo's own (component-map.md §1).
//
// Why the pill is not a `Button`:
//  - a long press on a `Button` and a tap on the same element compete, and T35 measured that a long
//    press inside a row's `Text` opens the *system* text menu on iOS 26, so the affordance a reader
//    reaches for has to be an explicit gesture pair on a plain view (`onTapGesture` +
//    `onLongPressGesture`), with the button trait re-added for VoiceOver. That keeps both gestures
//    reachable and both addressable from a UI test (`press(forDuration:)` is a long press).
//  - the accessibility contract from T34 is unchanged: the same identifier
//    (`post.<id>.reaction.<emoji>`) and the same label ("<emoji> <count>"), so the channel-list suite
//    that already asserts the pill keeps asserting it.

import SwiftUI

struct ReactionBarView: View {
    let rowID: String
    let reactions: [PostReactionSummary]
    var emoji: EmojiCatalogue?
    /// Tap a pill: toggle that reaction. Nil keeps the bar read-only (previews, web renders).
    var onToggle: ((String) -> Void)? = nil
    /// Long-press a pill: who reacted.
    var onShowReactors: ((String) -> Void)? = nil
    /// The trailing `+`: open the picker for this post.
    var onAdd: (() -> Void)? = nil

    private var isInteractive: Bool { onToggle != nil || onShowReactors != nil }

    /// The row's handler bundle: nil handlers keep the bar read-only (previews, web renders).
    init(rowID: String,
         reactions: [PostReactionSummary],
         emoji: EmojiCatalogue? = nil,
         actions: PostRowReactionActions?) {
        self.rowID = rowID
        self.reactions = reactions
        self.emoji = emoji
        self.onToggle = actions?.onToggle
        self.onShowReactors = actions?.onShowReactors
        self.onAdd = actions?.onAdd
    }

    var body: some View {
        // The bar is shown only when there is something in it; the *way to add a first reaction* is
        // the row menu's `React` entry (T37, `PostOptionsSheet`), so an untouched message is not
        // decorated with a chip it does not need.
        if !reactions.isEmpty {
            HStack(spacing: 6) {
                ForEach(reactions) { reaction in
                    pill(reaction)
                }
                if let onAdd {
                    addButton(onAdd)
                }
            }
            .padding(.top, 2)
        }
    }

    private func pill(_ reaction: PostReactionSummary) -> some View {
        HStack(spacing: 3) {
            EmojiGlyph(name: reaction.emojiName, emoji: emoji)
            Text("\(reaction.count)")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(reaction.includesMe
                    ? Color.accentColor.opacity(0.16)
                    : Color(.secondarySystemBackground),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(
            reaction.includesMe ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Capsule())
        .onTapGesture {
            onToggle?(reaction.emojiName)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onShowReactors?(reaction.emojiName)
        }
        .allowsHitTesting(isInteractive)
        .accessibilityElement(children: .combine)
        // Unchanged from T34: the suite asserts `label.contains("<count>")` and resolves the pill by
        // this identifier.
        .accessibilityLabel("\(reaction.emojiName) \(reaction.count)")
        .accessibilityValue(reaction.includesMe ? "You reacted" : "")
        .accessibilityHint(isInteractive ? "Double-tap to toggle. Touch and hold to see who reacted."
                                         : "")
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityAction(named: Text("Who reacted")) {
            onShowReactors?(reaction.emojiName)
        }
        .accessibilityIdentifier("post.\(rowID).reaction.\(reaction.emojiName)")
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "face.smiling")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a reaction")
        .accessibilityIdentifier("post.\(rowID).addReaction")
    }
}
