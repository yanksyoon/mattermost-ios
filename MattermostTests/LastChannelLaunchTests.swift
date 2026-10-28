// Where the app opens: the last conversation, or the channel list — never an invented channel.
//
// Upstream's cold start restores the last thread, else the last channel, else routes to the channel
// list with `setLoadTarget('HOME')` (`mattermost-mobile` v2.45.0 = `162f2560`, `app/init/launch.ts`
// `:245-262`, `:290-294`). There is no town-hall or first-channel fallback, so neither is there one
// here: the four cases below are the whole policy (`docs/t95-shell-tab-bar-decision.md` §3).

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

    private func request(saved: LastChannel?, available: Set<String> = []) -> NativeChannelRequest? {
        LaunchDestination.request(saved: saved,
                                  available: available,
                                  serverID: serverID,
                                  teamID: "team-1",
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

    // MARK: - The launch policy: four cases, and only these four

    /// 1. A saved channel that is still in the sidebar → that channel.
    func testTheSavedChannelWinsWhenItStillExists() {
        let request = request(saved: saved(channelID: "chan-9", name: "ops-standup"),
                              available: ["chan-1", "chan-9"])

        XCTAssertEqual(request?.channelID, "chan-9")
        XCTAssertEqual(request?.channelName, "ops-standup")
        XCTAssertEqual(request?.serverID, serverID)
    }

    /// 2. A saved channel that is gone (left, archived, deleted) → nothing. It must not be opened
    ///    blindly: the pane would show an error instead of a conversation.
    func testASavedChannelThatIsGoneOpensNothing() {
        let request = request(saved: saved(channelID: "chan-deleted", name: "old"),
                             available: ["chan-1", "chan-town"])

        XCTAssertNil(request,
                     "a saved channel that is no longer in the list must not be opened, and must not "
                     + "be replaced by an invented one")
    }

    /// 3. Nothing saved → nothing. Upstream lands on the channel list (`HOME`), and so does the
    ///    shell: no town hall, no "first ordinary channel".
    func testNothingSavedOpensNothing() {
        XCTAssertNil(request(saved: nil, available: ["chan-1", "chan-town"]),
                     "with nothing saved the destination is the channel list, as upstream's HOME is")
        XCTAssertNil(request(saved: nil, available: []),
                     "an empty, not-yet-loaded list must not become an occasion to invent a channel")
    }

    /// 4. A saved channel from another server → nothing, even when this server's list holds a channel
    ///    with the same name.
    func testASavedChannelFromAnotherServerOpensNothing() {
        let request = request(saved: saved(channelID: "chan-9", name: "ops-standup", on: UUID()),
                              available: ["chan-9", "ops-standup"])

        XCTAssertNil(request,
                     "one server's saved channel must never be opened against another")
    }

    // MARK: - The two rules that survive unchanged

    /// Before the directory loads there is nothing to contradict the saved channel, so it is trusted
    /// and the pane is the judge. (Deferring until the list arrives is what made an unloaded list
    /// indistinguishable from "nothing saved".)
    func testAnUnloadedListTrustsTheSavedChannel() {
        let request = request(saved: saved(channelID: "chan-9", name: "ops-standup"), available: [])

        XCTAssertEqual(request?.channelID, "chan-9",
                       "before the list loads there is nothing to contradict the saved channel")
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

        let request = request(saved: record, available: ["chan-9"])

        XCTAssertEqual(request?.channelID, "chan-9")
        XCTAssertEqual(request?.teamID, "team-1")
        XCTAssertEqual(request?.teamName, "canonical")
    }

    func testAnotherServersRecordIsNotReadBack() {
        let store = store()
        store.save(saved(channelID: "chan-9", name: "ops-standup", on: UUID()))

        XCTAssertNil(store.last(for: serverID),
                     "a saved channel from another server must not be opened against this one")
    }
}
