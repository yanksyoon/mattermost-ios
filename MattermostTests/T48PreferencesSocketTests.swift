// T48-R: the preference frames as 9.11.19 actually sends them.
//
// Card t_fddfb0d5. The card's gap was "preferences_changed does not move an already open post
// options menu", while the pin→Unpin hop (a `post_edited` frame) did land. T48-AV measured the wire
// (`scripts/t48_av_probe.py`, build/logs/t48av-probe.log, save then unsave on 9.11.19) and found the
// payload shape, not the coordinator: `data.preferences` is a **JSON string**
// (`preferences_type: "str"`), and `SocketEvent.init(frame:)` guarded on `arrayValue`, which is nil
// for a string — so the whole frame was dropped and `.preferencesChanged` / `.preferencesDeleted`
// never existed against a live server.
//
// These tests feed the captured forms, not a shape invented to match the code. The regression guard
// is the string case: it is the real wire, and the old guard fails it.
//
// Licence: not ported — these are this repo's tests against this repo's decoder.

import XCTest
@testable import Mattermost

final class T48PreferencesSocketTests: XCTestCase {

    /// Verbatim `data.preferences` from `t48av-probe.log` (`[save]`, and the identical `[unsave]`
    /// payload): the list arrives escaped as a string, `preferences_type: "str"`.
    private let measuredString =
        "[{\"user_id\":\"jruqqzxtobg7tn4wehwmwjjo5c\",\"category\":\"flagged_post\"," +
        "\"name\":\"4nmfh6s7678fjjuekw8ykhb43c\",\"value\":\"true\"}]"

    private func frame(_ name: String, preferences: Any) throws -> MMSocketFrame {
        let data: [String: Any] = ["preferences": preferences]
        let object: [String: Any] = ["event": name,
                                     "seq": 1,
                                     "data": data,
                                     "broadcast": ["user_id": "", "channel_id": "", "team_id": ""]]
        let json = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MMSocketFrame.self, from: json)
    }

    /// The measured save frame: a string payload must decode into `.preferencesChanged`, and the row
    /// must survive whole (`user_id`, `category`, `name`, `value`) — the menu reads the category/name
    /// pair, the Saved screen reads the flag.
    func testTheMeasuredStringShapedSaveFrameDecodes() throws {
        let frame = try frame("preferences_changed", preferences: measuredString)

        guard case .preferencesChanged(let preferences)? = SocketEvent(frame: frame) else {
            return XCTFail("""
                a string-shaped preferences_changed frame must decode; 9.11.19 sends \
                `data.preferences` as a JSON string (preferences_type "str") and the arrayValue \
                guard dropped every live frame
                """)
        }
        XCTAssertEqual(preferences.count, 1)
        XCTAssertEqual(preferences.first?.userId, "jruqqzxtobg7tn4wehwmwjjo5c")
        XCTAssertEqual(preferences.first?.category, "flagged_post")
        XCTAssertEqual(preferences.first?.name, "4nmfh6s7678fjjuekw8ykhb43c")
        XCTAssertEqual(preferences.first?.value, "true")
    }

    /// The measured unsave frame: same string shape, its own event name (`preferences_deleted`), the
    /// same row — the menu's Remove→Save direction.
    func testTheMeasuredStringShapedUnsaveFrameDecodes() throws {
        let frame = try frame("preferences_deleted", preferences: measuredString)

        guard case .preferencesDeleted(let preferences)? = SocketEvent(frame: frame) else {
            return XCTFail("a string-shaped preferences_deleted frame must decode")
        }
        XCTAssertEqual(preferences.first?.category, "flagged_post")
        XCTAssertEqual(preferences.first?.name, "4nmfh6s7678fjjuekw8ykhb43c")
    }

    /// The array shape is still accepted (some proxies and newer builds send the list directly, and
    /// the unit fixture has always used it). Accepting the string must not cost the old shape.
    func testTheArrayShapedFrameStillDecodes() throws {
        let frame = try frame("preferences_changed", preferences: [[
            "user_id": "u1", "category": "flagged_post", "name": "p1", "value": "true"
        ]])

        guard case .preferencesChanged(let preferences)? = SocketEvent(frame: frame) else {
            return XCTFail("an array-shaped preferences_changed frame must still decode")
        }
        XCTAssertEqual(preferences, [MMPreference(userId: "u1", category: "flagged_post",
                                                  name: "p1", value: "true")])
    }

    /// A payload that is neither shape is still dropped rather than turned into an empty event: the
    /// fix widens the accepted shapes, it does not make every frame "decodable".
    func testAMalformedPreferencePayloadIsStillDropped() throws {
        let frame = try frame("preferences_changed", preferences: "not json")

        XCTAssertNil(SocketEvent(frame: frame),
                     "a preference payload that parses as neither a string-encoded list nor a list "
                       + "must not be reported as a preference change")
    }
}
