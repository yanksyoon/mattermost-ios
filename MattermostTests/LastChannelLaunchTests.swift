// Where the app opens: the last conversation, else the team's town hall, else its first ordinary
// channel, else the channel list.
//
// The product owner's requirement (2026-10-27): "launch into last opened channel, or default to town
// hall." Upstream's cold start is last thread → last channel → `HOME`
// (`mattermost-mobile` v2.45.0 = `162f2560`, `app/init/launch.ts:245-262`, `:290-294`) and has no
// town-hall fallback; T95-A removed ours to match it (`docs/t95-shell-tab-bar-decision.md` §3) and the
// owner called that a regression (card t_295b0a32). The chain is back.
//
// What survives from T95-A has its own cases below: a saved channel that is gone falls *through*
// instead of being opened blindly (the pane would answer with an error), and the fallbacks never run
// against a list that has not loaded.

import XCTest
@testable import Mattermost

final class LastChannelLaunchTests: XCTestCase {
    private let serverID = UUID()

    private func store() -> LastChannelStore {
        let defaults = UserDefaults(suiteName: "last-channel-tests-\(UUID().uuidString)")!
        return LastChannelStore(defaults: defaults)
    }

    private func saved(channelID: String, name: String, on server: UUID? = nil) -> LastChannel {
        LastChannel(serverID: server ?? serverID,
                    teamID: "team-1",
                    teamName: "canonical",
                    channelID: channelID,
                    channelName: name,
                    openedAt: Date())
    }

    private let townHall = LaunchDestination.Candidate(id: "chan-town", name: "town-square")
    private let firstOrdinary = LaunchDestination.Candidate(id: "chan-1", name: "general")

    private func resolve(saved: LastChannel?,
                         available: Set<String> = [],
                         townHall: LaunchDestination.Candidate? = nil,
                         fallback: LaunchDestination.Candidate? = nil,
                         teamID: String? = "team-1") -> LaunchDestination.Resolution? {
        LaunchDestination.resolve(saved: saved,
                                  available: available,
                                  townHall: townHall,
                                  fallback: fallback,
                                  serverID: serverID,
                                  teamID: teamID,
                                  teamName: "canonical")
    }

    private func request(saved: LastChannel?,
                         available: Set<String> = [],
                         townHall: LaunchDestination.Candidate? = nil,
                         fallback: LaunchDestination.Candidate? = nil,
                         teamID: String? = "team-1") -> NativeChannelRequest? {
        LaunchDestination.request(saved: saved,
                                  available: available,
                                  townHall: townHall,
                                  fallback: fallback,
                                  serverID: serverID,
                                  teamID: teamID,
                                  teamName: "canonical")
    }

    func testTheLastChannelSurvivesAProcess() {
        let defaults = UserDefaults(suiteName: "last-channel-\(UUID().uuidString)")!
        let first = LastChannelStore(defaults: defaults)
        first.save(saved(channelID: "chan-9", name: "ops-standup"))

        let second = LastChannelStore(defaults: defaults)
        let restored = second.last(for: serverID)

        XCTAssertEqual(restored?.channelID, "chan-9")
        XCTAssertEqual(restored?.channelName, "ops-standup")
        XCTAssertEqual(restored?.teamID, "team-1")
    }

    // MARK: - 1. The saved channel wins while it exists

    /// A saved channel that is still in the sidebar → that channel, even though the team also has a
    /// town hall the chain would otherwise pick.
    func testTheSavedChannelWinsWhenItStillExists() {
        let resolution = resolve(saved: saved(channelID: "chan-9", name: "ops-standup"),
                                 available: ["chan-1", "chan-9", "chan-town"],
                                 townHall: townHall,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-9")
        XCTAssertEqual(resolution?.request.channelName, "ops-standup")
        XCTAssertEqual(resolution?.request.serverID, serverID)
        XCTAssertEqual(resolution?.origin, .saved)
    }

    // MARK: - 2. A saved channel that is gone falls through

    /// Left / archived / deleted → the town hall: never the dead id (the pane would error), never
    /// `nil` (which is what left the reader on "No channel selected" every launch).
    func testASavedChannelThatIsGoneFallsThroughToTheTownHall() {
        let resolution = resolve(saved: saved(channelID: "chan-deleted", name: "old"),
                                 available: ["chan-1", "chan-town"],
                                 townHall: townHall,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-town",
                       "a saved channel that is gone must fall through to the town hall rather than "
                       + "be opened (the pane would error) or be dropped (the pane stays empty)")
        XCTAssertEqual(resolution?.request.channelName, "town-square")
        XCTAssertEqual(resolution?.request.teamID, "team-1")
        XCTAssertEqual(resolution?.origin, .townHall)
    }

    /// A team with no recognisable town hall: the first ordinary channel is still a conversation.
    func testASavedChannelThatIsGoneFallsThroughToTheFirstOrdinaryChannelWhenThereIsNoTownHall() {
        let resolution = resolve(saved: saved(channelID: "chan-deleted", name: "old"),
                                 available: ["chan-1", "chan-2"],
                                 townHall: nil,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-1")
        XCTAssertEqual(resolution?.origin, .firstChannel)
    }

    // MARK: - 3. Nothing saved → the team's default

    /// The regression this card is about: a first launch (no saved record) with a loaded list lands
    /// on the team's town hall, not on "No channel selected".
    func testNothingSavedOpensTheTownHall() {
        let resolution = resolve(saved: nil,
                                 available: ["chan-1", "chan-town"],
                                 townHall: townHall,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-town",
                       "the owner's instruction: last opened channel, else the team's town hall")
        XCTAssertEqual(resolution?.request.channelName, "town-square")
        XCTAssertEqual(resolution?.request.teamID, "team-1")
        XCTAssertEqual(resolution?.request.teamName, "canonical")
        XCTAssertEqual(resolution?.origin, .townHall)
    }

    /// `town-hall` is the name the measured fixture uses (the admins renamed Mattermost's
    /// `town-square`); the coordinator resolves the name from the sidebar rows, so both spellings
    /// reach the same decision.
    func testTheTownHallIsRecognisedByEitherName() {
        XCTAssertEqual(LaunchDestination.townHallNames, ["town-square", "town-hall"])
        XCTAssertEqual(LaunchDestination.townHall, "town-square")
    }

    // MARK: - 4. No town hall → the first ordinary channel

    func testATeamWithNoTownHallOpensItsFirstOrdinaryChannel() {
        let resolution = resolve(saved: nil,
                                 available: ["chan-1", "chan-2"],
                                 townHall: nil,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-1",
                       "without a town hall the shell opens a conversation rather than nothing — "
                       + "that is the state this card fixes")
        XCTAssertEqual(resolution?.request.channelName, "general")
        XCTAssertEqual(resolution?.origin, .firstChannel)
    }

    // MARK: - 5. The chain never invents a channel against an unloaded list

    /// `available` empty means "the sidebar has not read the team's channels yet". There is nothing
    /// to pick from, and picking blindly is what T95-A measured as a fabricated push.
    func testNothingSavedWithAnUnloadedListOpensNothing() {
        XCTAssertNil(request(saved: nil, available: [], townHall: townHall, fallback: firstOrdinary),
                     "an empty, not-yet-loaded list must not become an occasion to invent a channel")
        XCTAssertNil(resolve(saved: nil, available: [], townHall: townHall, fallback: firstOrdinary))
    }

    // MARK: - 6. The record belongs to one server

    /// A saved record from another server is not this server's fact, and the chain belongs to *this*
    /// server: the other server's channel is never named, this server's town hall is.
    func testASavedChannelFromAnotherServerFallsThroughToThisServersTownHall() {
        let resolution = resolve(saved: saved(channelID: "chan-9", name: "ops-standup", on: UUID()),
                                 available: ["chan-9", "ops-standup", "chan-town"],
                                 townHall: townHall,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-town",
                       "one server's saved channel must never be opened against another")
        XCTAssertEqual(resolution?.request.serverID, serverID)
    }

    func testAnotherServersRecordIsNotReadBack() {
        let store = store()
        store.save(saved(channelID: "chan-9", name: "ops-standup", on: UUID()))

        XCTAssertNil(store.last(for: serverID),
                     "a saved channel from another server must not be read back for this one")
    }

    /// No team (the rail has not picked one) → no fallback: every fallback request needs a team.
    func testNoTeamOpensNoFallback() {
        XCTAssertNil(resolve(saved: nil,
                             available: ["chan-1", "chan-town"],
                             townHall: townHall,
                             fallback: firstOrdinary,
                             teamID: nil),
                     "a fallback cannot be addressed without a team")
    }

    /// A candidate the list does not actually contain is not a destination — the chain falls to the
    /// next rung instead of opening an id the sidebar has never seen.
    func testACandidateMissingFromTheListIsSkipped() {
        let resolution = resolve(saved: nil,
                                 available: ["chan-1", "chan-2"],
                                 townHall: .init(id: "chan-old-town", name: "town-square"),
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-1")
        XCTAssertEqual(resolution?.origin, .firstChannel)
    }

    // MARK: - The two rules that survive unchanged from T95-A

    /// Before the directory loads there is nothing to contradict the saved channel, so it is trusted
    /// and the pane is the judge. (Deferring until the list arrives is what made an unloaded list
    /// indistinguishable from "nothing saved".)
    func testAnUnloadedListTrustsTheSavedChannel() {
        let resolution = resolve(saved: saved(channelID: "chan-9", name: "ops-standup"),
                                 available: [],
                                 townHall: townHall,
                                 fallback: firstOrdinary)

        XCTAssertEqual(resolution?.request.channelID, "chan-9",
                       "before the list loads there is nothing to contradict the saved channel")
        XCTAssertEqual(resolution?.origin, .saved)
    }

    /// The record carries its own team; a record written without one is completed from the launch
    /// context so the pane can resolve the channel. The record's values always win.
    func testASavedRecordWithoutATeamIsCompletedFromTheLaunch() {
        let record = LastChannel(serverID: serverID,
                                 teamID: nil,
                                 teamName: nil,
                                 channelID: "chan-9",
                                 channelName: "ops-standup",
                                 openedAt: Date())

        let resolution = resolve(saved: record, available: ["chan-9"])

        XCTAssertEqual(resolution?.request.channelID, "chan-9")
        XCTAssertEqual(resolution?.request.teamID, "team-1")
        XCTAssertEqual(resolution?.request.teamName, "canonical")
    }
}
