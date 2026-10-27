// T35 — the composer's **pure logic**: the autocomplete trigger, the insertion each suggestion
// performs, the markdown toolbar, the multipart body, the membership filter, the draft row mapping.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
// `app/components/autocomplete/*`, `app/components/post_draft/draft_input/draft_input.tsx`,
// `app/client/rest/files.ts`; licence Apache-2.0, see docs/THIRD_PARTY_NOTICES.md §12.
//
// Nothing here touches a network, a clock, GRDB or SwiftUI: every rule under test is a function of
// its arguments, which is why the boundary cases (caret at 0, a surrogate pair before the sigil, a
// selection that ends on a line break, a filename containing a quote) can be pinned exactly.

import XCTest
@testable import Mattermost

final class T35ComposerModelsTests: XCTestCase {

    // MARK: - The trigger

    func testAMentionIsTheWordBeforeTheCaret() {
        let trigger = ComposerTriggerParser.trigger(in: "hi @ki", caret: 6)
        XCTAssertEqual(trigger?.kind, .mention)
        XCTAssertEqual(trigger?.term, "ki")
        XCTAssertEqual(trigger?.range, NSRange(location: 3, length: 3))
    }

    func testABareSigilIsAValidTrigger() {
        // `@` with nothing after it still offers the list: that is how a person discovers who exists.
        let trigger = ComposerTriggerParser.trigger(in: "@", caret: 1)
        XCTAssertEqual(trigger?.kind, .mention)
        XCTAssertEqual(trigger?.term, "")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 1))
    }

    func testAnEmailAddressIsNotAMention() {
        // The sigil has to be the word's first character. Without this rule every email in a post
        // opens the mention list.
        let text = "mail me at ada@example.com"
        XCTAssertNil(ComposerTriggerParser.trigger(in: text, caret: (text as NSString).length))
    }

    func testAClosedShortcodeIsFinishedText() {
        XCTAssertNil(ComposerTriggerParser.trigger(in: ":smile:", caret: 7))
        let open = ComposerTriggerParser.trigger(in: ":smi", caret: 4)
        XCTAssertEqual(open?.kind, .emoji)
        XCTAssertEqual(open?.term, "smi")
    }

    func testAChannelTriggerIsHashAndAMarkdownHeadingIsNot() {
        let channel = ComposerTriggerParser.trigger(in: "see #town", caret: 9)
        XCTAssertEqual(channel?.kind, .channel)
        XCTAssertEqual(channel?.term, "town")
        // `# ` is a heading, and `##` is not a channel name.
        XCTAssertNil(ComposerTriggerParser.trigger(in: "# heading", caret: 9))
        XCTAssertNil(ComposerTriggerParser.trigger(in: "##", caret: 2))
    }

    func testNoTriggerAfterWhitespaceOrAtTheStart() {
        XCTAssertNil(ComposerTriggerParser.trigger(in: "", caret: 0))
        XCTAssertNil(ComposerTriggerParser.trigger(in: "hello ", caret: 6))
        // A newline is a boundary, so `@` on a fresh line is a trigger and the line above is not.
        let afterNewline = ComposerTriggerParser.trigger(in: "hello\n@ki", caret: 9)
        XCTAssertEqual(afterNewline?.term, "ki")
        XCTAssertEqual(afterNewline?.range, NSRange(location: 6, length: 3))
    }

    func testTheRangeIsUTF16SoASurrogatePairBeforeTheSigilDoesNotShiftIt() {
        // "🎉" is two UTF-16 units. `UITextView` reports UTF-16 offsets; a range computed in
        // `Character`s would point one unit too far left and replace the emoji.
        let text = "🎉 @ki"
        XCTAssertEqual((text as NSString).length, 6)
        let trigger = ComposerTriggerParser.trigger(in: text, caret: 6)
        XCTAssertEqual(trigger?.range, NSRange(location: 3, length: 3))
    }

    func testACaretBeyondTheTextIsNotATrigger() {
        XCTAssertNil(ComposerTriggerParser.trigger(in: "abc", caret: 10))
        XCTAssertNil(ComposerTriggerParser.trigger(in: "abc", caret: -1))
    }

    // MARK: - Insertion

    func testEachSuggestionKindInsertsItsOwnSyntax() {
        XCTAssertEqual(mentionInsertion("ada"), "@ada")
        // The trigger is `#`, but Mattermost's channel-link syntax is `~name`, with spaces as dashes.
        XCTAssertEqual(channelInsertion("town square"), "~town-square")
        XCTAssertEqual(emojiInsertion("tada"), ":tada:")
    }

    func testApplyReplacesTheTriggerAndAddsOneSpace() {
        let trigger = ComposerTriggerParser.trigger(in: "hi @ki", caret: 6)!
        let suggestion = ComposerSuggestion(kind: .user, value: "kim.park", label: "Kim Park",
                                            detail: "@kim.park", insertion: "@kim.park", glyph: nil)
        let result = ComposerTriggerParser.apply(suggestion, to: "hi @ki", trigger: trigger)
        XCTAssertEqual(result?.text, "hi @kim.park ")
        XCTAssertEqual(result?.caret, ("hi @kim.park " as NSString).length)
    }

    func testApplyDoesNotAddASecondSpace() {
        let trigger = ComposerTriggerParser.trigger(in: "hi @ki there", caret: 6)!
        let suggestion = ComposerSuggestion(kind: .user, value: "kim", label: "Kim", detail: "",
                                            insertion: "@kim", glyph: nil)
        let result = ComposerTriggerParser.apply(suggestion, to: "hi @ki there", trigger: trigger)
        XCTAssertEqual(result?.text, "hi @kim there")
    }

    func testApplyRefusesAStaleRange() {
        // The text moved on since the list was drawn: applying at the remembered offset would edit
        // the wrong characters, so the edit is dropped instead.
        let trigger = ComposerTrigger(kind: .mention, term: "ki", range: NSRange(location: 3, length: 3))
        let suggestion = ComposerSuggestion(kind: .user, value: "kim", label: "Kim", detail: "",
                                            insertion: "@kim", glyph: nil)
        XCTAssertNil(ComposerTriggerParser.apply(suggestion, to: "hi", trigger: trigger))
    }

    // MARK: - Markdown toolbar

    func testBoldOnAnEmptySelectionPutsTheCaretBetweenTheMarkers() {
        let result = ComposerMarkdownEditing.apply(.bold, text: "hello", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(result.text, "hello****")
        // Caret between the two pairs: what makes "tap bold, then type" work.
        XCTAssertEqual(result.selection, NSRange(location: 7, length: 0))
    }

    func testBoldOnASelectionKeepsTheWordsSelected() {
        let result = ComposerMarkdownEditing.apply(.bold, text: "hello world",
                                                   selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(result.text, "hello **world**")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 5))
    }

    func testLinkSelectsTheURLPlaceholder() {
        let result = ComposerMarkdownEditing.apply(.link, text: "docs", selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(result.text, "[docs](url)")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "url")
    }

    func testQuotePrefixesEveryTouchedLine() {
        let text = "one\ntwo\nthree"
        let result = ComposerMarkdownEditing.apply(.quote, text: text,
                                                  selection: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(result.text, "> one\n> two\n> three")
    }

    func testASelectionEndingOnALineBreakDoesNotTouchTheNextLine() {
        // The selection is "one" and ends *on* the line break: the last touched line is "one", not
        // "two", so only one bullet is inserted.
        let result = ComposerMarkdownEditing.apply(.bulletList, text: "one\ntwo",
                                                   selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(result.text, "- one\ntwo")
    }

    func testASelectionOutsideTheTextIsClamped() {
        let result = ComposerMarkdownEditing.apply(.bold, text: "ab", selection: NSRange(location: 99, length: 99))
        XCTAssertEqual(result.text, "ab****")
    }

    func testMessageForSendingTrimsOnlyTheEnds() {
        let body = ComposerMarkdownEditing.messageForSending("\n\n  ```\n  code\n  ```  \n\n")
        XCTAssertEqual(body, "```\n  code\n  ```")
        XCTAssertEqual(ComposerMarkdownEditing.messageForSending("   \n\t"), "")
    }

    // MARK: - Multipart

    func testTheMultipartBodyIsExactlyTheDocumentedLayout() {
        let encoded = MMMultipart.encode(fields: [MMMultipart.Field(name: "channel_id", value: "chan-1")],
                                         files: [MMMultipart.File(fieldName: "files",
                                                                  filename: "a.png",
                                                                  mimeType: "image/png",
                                                                  data: Data([1, 2, 3]))],
                                         boundary: "B")

        var expected = Data()
        let header = "--B\r\n"
            + "Content-Disposition: form-data; name=\"channel_id\"\r\n\r\n"
            + "chan-1\r\n"
            + "--B\r\n"
            + "Content-Disposition: form-data; name=\"files\"; filename=\"a.png\"\r\n"
            + "Content-Type: image/png\r\n\r\n"
        expected.append(Data(header.utf8))
        expected.append(Data([1, 2, 3]))
        expected.append(Data("\r\n--B--\r\n".utf8))

        XCTAssertEqual(encoded.body, expected)
        XCTAssertEqual(encoded.contentType, "multipart/form-data; boundary=B")
    }

    func testAFilenameCannotBreakOutOfItsHeader() {
        // Each of these would end the quoted-string or the header line, and the bytes would then be
        // an arbitrary request the app built on the person's behalf.
        XCTAssertEqual(MMMultipart.sanitizedFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(MMMultipart.sanitizedFilename("a\"b.png"), "a_b.png")
        XCTAssertEqual(MMMultipart.sanitizedFilename("a\r\nX-Evil: 1.png"), "a__X-Evil: 1.png")
        XCTAssertEqual(MMMultipart.sanitizedFilename("   "), "upload")
        XCTAssertEqual(MMMultipart.sanitizedFilename("..."), "upload")
    }

    func testTheEncodedBodyUsesTheSanitisedFilename() {
        let encoded = MMMultipart.encode(fields: [], files: [MMMultipart.File(fieldName: "files",
                                                                              filename: "../x/\"y\".txt",
                                                                              mimeType: "text/plain",
                                                                              data: Data())],
                                         boundary: "B")
        let text = String(decoding: encoded.body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"_y_.txt\""), text)
        XCTAssertFalse(text.contains("../"))
    }

    func testTheContentTypeIsValidatedAndFallsBack() {
        XCTAssertEqual(MMMultipart.headerSafe("image/png\r\nX-Evil: 1"), "image/pngX-Evil: 1")
        XCTAssertEqual(MMMultipart.headerSafe("   "), "application/octet-stream")
        XCTAssertEqual(MMMultipart.mimeType(forFilename: "a.PNG"), "image/png")
        XCTAssertEqual(MMMultipart.mimeType(forFilename: "no-extension"), "application/octet-stream")
    }

    // MARK: - Membership

    func testACompleteMemberListDropsNonMembers() {
        let members = ComposerMembership.MemberList(ids: ["u1", "u2"], isComplete: true)
        let candidates = [
            ComposerSuggestion(kind: .user, value: "kim", label: "One", detail: "",
                               insertion: "@kim", glyph: nil, userID: "u1"),
            ComposerSuggestion(kind: .user, value: "outsider", label: "Out", detail: "",
                               insertion: "@outsider", glyph: nil, userID: "u9"),
            // A row with no server id cannot be checked, so it is kept rather than guessed about.
            ComposerSuggestion(kind: .user, value: "unknown", label: "Unknown", detail: "",
                               insertion: "@unknown", glyph: nil),
            ComposerSuggestion(kind: .specialMention, value: "channel", label: "@channel", detail: "",
                               insertion: "@channel", glyph: nil)
        ]
        let filtered = ComposerMembership.filter(candidates, members: members)
        XCTAssertEqual(filtered.map(\.value), ["kim", "unknown", "channel"])
    }

    func testATruncatedMemberListStandsDown() {
        // A large channel, or a failed page: an autocomplete that hides a real colleague is worse
        // than one that offers a stale name, because the mention works either way.
        let members = ComposerMembership.MemberList(ids: ["u1"], isComplete: false)
        let candidates = [
            ComposerSuggestion(kind: .user, value: "u9", label: "Nine", detail: "", insertion: "@u9", glyph: nil)
        ]
        XCTAssertEqual(ComposerMembership.filter(candidates, members: members).count, 1)
        XCTAssertEqual(ComposerMembership.filter(candidates, members: .unknown).count, 1)
    }

    // MARK: - Ranking

    func testPrefixMatchesComeBeforeSubstringMatches() {
        let suggestions = [
            ComposerSuggestion(kind: .user, value: "another-kim", label: "Another", detail: "",
                               insertion: "@another-kim", glyph: nil),
            ComposerSuggestion(kind: .user, value: "kim.park", label: "Kim", detail: "",
                               insertion: "@kim.park", glyph: nil)
        ]
        let ranked = ComposerSuggestionRanking.ranked(suggestions, term: "kim")
        XCTAssertEqual(ranked.map(\.value), ["kim.park", "another-kim"])
    }

    func testRankingKeepsTheServersOrderOnTiesAndHonoursTheLimit() {
        let suggestions = (1...5).map { index in
            ComposerSuggestion(kind: .user, value: "kim\(index)", label: "Kim \(index)", detail: "",
                               insertion: "@kim\(index)", glyph: nil)
        }
        XCTAssertEqual(ComposerSuggestionRanking.ranked(suggestions, term: "kim", limit: 3).map(\.value),
                       ["kim1", "kim2", "kim3"])
        XCTAssertEqual(ComposerSuggestionRanking.ranked(suggestions, term: "", limit: 2).count, 2)
        XCTAssertTrue(ComposerSuggestionRanking.ranked(suggestions, term: "kim", limit: 0).isEmpty)
    }

    // MARK: - Request bodies

    func testTheCreateBodyUsesTheDocumentedFieldNames() throws {
        let body = ComposerPostBody(channelId: "c1", message: "hi", rootId: nil,
                                    fileIds: ["f1"], pendingPostId: "pending:1")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(json?["channel_id"] as? String, "c1")
        XCTAssertEqual(json?["pending_post_id"] as? String, "pending:1")
        XCTAssertEqual(json?["file_ids"] as? [String], ["f1"])
        // Ah omitted `root_id` is an empty string on the wire, not the literal "null" upstream sends
        // for a top-level post; the server treats both as "not a reply", and omitting it keeps the
        // body minimal.
        XCTAssertNil(json?["root_id"])
    }

    func testThePatchBodyCarriesThePostId() throws {
        let patch = ComposerPostPatch(id: "p1", message: "edited", fileIds: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
        XCTAssertEqual(json?["id"] as? String, "p1")
        XCTAssertEqual(json?["message"] as? String, "edited")
    }

    // MARK: - Drafts

    func testADraftRoundTripsThroughTheStoreRow() {
        let draft = ComposerDraft(channelID: "c1", rootID: "r1", message: "half a thought",
                                  files: [ComposerStoredFile(id: "f1", name: "a.png",
                                                             mimeType: "image/png", size: 3)],
                                  updateAt: 42)
        let restored = ComposerDraftMapping.draft(ComposerDraftMapping.row(draft))
        XCTAssertEqual(restored, draft)
    }

    func testAMalformedFileBlobKeepsTheMessage() {
        // Losing the text because an attachment list cannot be read would be the worst failure here.
        let row = MMDraft(channelId: "c1", message: "keep me", files: .string("not-an-array"), updateAt: 1)
        let draft = ComposerDraftMapping.draft(row)
        XCTAssertEqual(draft.message, "keep me")
        XCTAssertTrue(draft.files.isEmpty)
    }

    func testADraftWithNothingInItIsEmpty() {
        XCTAssertTrue(ComposerDraft(channelID: "c1").isEmpty)
        XCTAssertFalse(ComposerDraft(channelID: "c1", message: " ").isEmpty)
        XCTAssertFalse(ComposerDraft(channelID: "c1",
                                     files: [ComposerStoredFile(id: "f", name: "n", mimeType: "m", size: 1)]).isEmpty)
    }

    // MARK: - Attachment rows

    func testAnAttachmentSizesItselfLikeAPostAttachment() {
        let upload = ComposerUpload(filename: "../evil.png", mimeType: "image/png", data: Data(repeating: 0, count: 2048))
        XCTAssertEqual(upload.safeFilename, "evil.png")
        XCTAssertEqual(upload.sizeBytes, 2048)
        let attachment = ComposerAttachment(id: upload.id, filename: upload.safeFilename,
                                            mimeType: upload.mimeType, sizeBytes: upload.sizeBytes,
                                            state: .uploaded(fileID: "f1"))
        XCTAssertEqual(attachment.sizeLabel, PostAttachment.sizeLabel(forBytes: 2048))
        XCTAssertEqual(attachment.fileID, "f1")
        XCTAssertFalse(attachment.isUploading)
    }

    // MARK: - Error copy

    func testTheComposersFailuresSayWhatHappenedToTheWords() {
        XCTAssertTrue(ComposerErrorCopy.message(for: MMError.offline).contains("saved"))
        XCTAssertTrue(ComposerErrorCopy.message(for: MMError.timeout).contains("still here"))
        XCTAssertFalse(ComposerErrorCopy.message(for: MMError.unauthorized(message: nil)).isEmpty)
        XCTAssertFalse(ComposerErrorCopy.message(for: MMError.forbidden(message: nil)).isEmpty)
        XCTAssertFalse(ComposerErrorCopy.message(for: MMError.rateLimited(retryAfter: nil)).isEmpty)
        XCTAssertEqual(ComposerErrorCopy.message(for: MMError.cancelled), "Cancelled.")
        // The server's own sentence is preferred over a generic one when it sent one.
        XCTAssertEqual(ComposerErrorCopy.message(for: MMError.client(status: 400,
                                                                    message: "Channel is archived")),
                       "Channel is archived")
    }

    // MARK: - Row permissions (the options sheet's rule)

    /// Edit and delete are only offered on a post I wrote — and "I cannot tell who wrote this" is
    /// never answered with "yes". The live suite's edit/delete test is the end-to-end proof; these
    /// pin the rule itself, including the two unknown cases.
    func testEditAndDeleteAreOnlyOfferedOnMyOwnPost() {
        XCTAssertTrue(ComposerRowPermissions.isMine(postUserID: "u1", authorID: "u1"))
        XCTAssertFalse(ComposerRowPermissions.isMine(postUserID: "u2", authorID: "u1"))
        // An empty post author (a row the server has not filled in) is not mine.
        XCTAssertFalse(ComposerRowPermissions.isMine(postUserID: "", authorID: "u1"))
        XCTAssertFalse(ComposerRowPermissions.isMine(postUserID: "   ", authorID: "u1"))
        // A session whose user id has not resolved yet cannot claim anyone's message.
        XCTAssertFalse(ComposerRowPermissions.isMine(postUserID: "u1", authorID: nil))
        XCTAssertFalse(ComposerRowPermissions.isMine(postUserID: "u1", authorID: ""))
    }

    func testTheRowMenuFollowsTheOwnershipRuleAndSkipsRowsThatAreNotFacts() {
        let mine = ComposerRowPermissions.menu(postUserID: "u1", authorID: "u1",
                                               isSystem: false, isDeleted: false, isPending: false)
        XCTAssertEqual(mine?.reply, true)
        XCTAssertEqual(mine?.edit, true)
        XCTAssertEqual(mine?.delete, true)

        let theirs = ComposerRowPermissions.menu(postUserID: "u2", authorID: "u1",
                                                 isSystem: false, isDeleted: false, isPending: false)
        XCTAssertEqual(theirs?.reply, true)
        XCTAssertEqual(theirs?.edit, false)
        XCTAssertEqual(theirs?.delete, false)

        // A system line, a tombstone and an optimistic row get no menu at all: there is nothing a
        // reader could do with them, and an empty sheet is a worse affordance than none.
        for (system, deleted, pending) in [(true, false, false), (false, true, false),
                                           (false, false, true)] {
            XCTAssertNil(ComposerRowPermissions.menu(postUserID: "u1", authorID: "u1",
                                                     isSystem: system, isDeleted: deleted,
                                                     isPending: pending),
                         "system=\(system) deleted=\(deleted) pending=\(pending)")
        }

        // Reply can be switched off (a non-native composer has no reply mode), and then a row that
        // is not mine has nothing to offer.
        XCTAssertNil(ComposerRowPermissions.menu(postUserID: "u2", authorID: "u1",
                                                 isSystem: false, isDeleted: false,
                                                 isPending: false, canReply: false))
    }
}

/// Enter sends, Shift+Enter is a newline — the rule the composer's text view asks before it lets a
/// `"\n"` through.
final class ComposerReturnPolicyTests: XCTestCase {

    func testReturnSends() {
        XCTAssertEqual(ComposerReturnPolicy.action(isReturnKey: true, shiftPressed: false), .send)
    }

    func testShiftReturnInsertsANewline() {
        XCTAssertEqual(ComposerReturnPolicy.action(isReturnKey: true, shiftPressed: true), .newline)
    }

    func testAnyOtherKeyIsLeftToTheTextSystem() {
        XCTAssertEqual(ComposerReturnPolicy.action(isReturnKey: false, shiftPressed: false), .passThrough)
        XCTAssertEqual(ComposerReturnPolicy.action(isReturnKey: false, shiftPressed: true), .passThrough)
    }
}
