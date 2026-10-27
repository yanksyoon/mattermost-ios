// Where the app opens: the last conversation, else the town hall.

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

    func testAnotherServersChannelIsNotOpened() {
        let store = store()
        store.save(saved(channelID: "chan-9", name: "ops-standup", on: UUID()))

        XCTAssertNil(store.last(for: serverID),
                     "a saved channel from another server must not be opened against this one")
    }

    func testTheSavedChannelWinsWhenItStillExists() {
        let request = LaunchDestination.request(saved: saved(channelID: "chan-9", name: "ops-standup"),
                                               available: ["chan-1", "chan-9"],
                                               townHallAvailable: true,
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertEqual(request?.channelID, "chan-9")
        XCTAssertEqual(request?.channelName, "ops-standup")
    }

    func testAChannelThatIsGoneFallsBackToTheTownHall() {
        let request = LaunchDestination.request(saved: saved(channelID: "chan-deleted", name: "old"),
                                               available: ["chan-1", "chan-town"],
                                               townHallAvailable: true,
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertEqual(request?.channelName, LaunchDestination.townHall)
        XCTAssertNil(request?.channelID)
    }

    func testNoSavedChannelOpensTheTownHall() {
        let request = LaunchDestination.request(saved: nil,
                                               available: ["chan-1", "chan-town"],
                                               townHallAvailable: true,
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertEqual(request?.channelName, LaunchDestination.townHall)
        XCTAssertEqual(request?.teamID, "team-1")
    }

    func testWithoutATownHallTheFirstOrdinaryChannelIsOpened() {
        let request = LaunchDestination.request(saved: nil,
                                               available: ["chan-1"],
                                               townHallAvailable: false,
                                               fallbackChannelID: "chan-1",
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertEqual(request?.channelID, "chan-1",
                       "a team with no town hall still has conversations")
    }

    func testWithNothingAtAllNothingIsOpened() {
        let request = LaunchDestination.request(saved: nil,
                                               available: [],
                                               townHallAvailable: false,
                                               fallbackChannelID: nil,
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertNil(request, "an empty team must not open a channel that is not there")
    }

    func testARenamedTownHallIsStillFound() {
        let request = LaunchDestination.request(saved: nil,
                                               available: ["chan-town"],
                                               townHallAvailable: true,
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertEqual(request?.channelName, LaunchDestination.townHall)
    }

    func testAnUnloadedListTrustsTheSavedChannel() {
        let request = LaunchDestination.request(saved: saved(channelID: "chan-9", name: "ops-standup"),
                                               available: [],
                                               townHallAvailable: true,
                                               serverID: serverID,
                                               teamID: "team-1",
                                               teamName: "canonical")

        XCTAssertEqual(request?.channelID, "chan-9",
                       "before the list loads there is nothing to contradict the saved channel")
    }
}
