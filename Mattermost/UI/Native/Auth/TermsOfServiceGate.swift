// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/queries/servers/terms_of_service.ts (the `showToS` rule: licensed + enabled + the user's
//        accepted id differs from the current document's id),
//        app/client/rest/tos.ts (`GET /terms_of_service`, `POST /users/me/terms_of_service`
//        with `{termsOfServiceId, accepted}`),
//        app/screens/terms_of_service/terms_of_service.tsx (blocking screen, Accept / Decline).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition and the pure gate are this repo's own.

import Foundation

// MARK: - The document the server publishes

/// The server's current custom Terms of Service, as `GET /api/v4/terms_of_service` returns it:
///
///     {"id":"<26>","create_at":1793644926809,"user_id":"<26>","text":"…"}
///
/// Decoded tolerantly (a missing `text` is an empty document, not a decode failure) because the
/// gate's job on a malformed answer is to *fail closed*, which needs the answer to arrive here
/// rather than to blow up as `MMError.malformedResponse` in the transport. `id` is the identity the
/// acceptance is compared against, so an empty id is rejected by `ServerTermsOfServiceAPI`.
struct TermsOfServiceDocument: Codable, Equatable, Sendable {
    var id: String
    var text: String
    var userID: String
    var createAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, text
        case userID = "user_id"
        case createAt = "create_at"
    }

    init(id: String, text: String = "", userID: String = "", createAt: Int64 = 0) {
        self.id = id
        self.text = text
        self.userID = userID
        self.createAt = createAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        userID = try values.decodeIfPresent(String.self, forKey: .userID) ?? ""
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
    }
}

// MARK: - What the gate knows

/// The answer to "may this user enter the workspace, terms-wise?".
///
/// Deliberately five cases, because the four acceptance criteria name four different answers and
/// the fifth is the honest "we have not asked yet":
///
///  - `.notRequired` — the server answered "no custom terms" (`404`, or `400` feature disabled):
///    a server with no TOS never sees the gate;
///  - `.pending` — a document exists and the user's accepted id is not it: **blocked**;
///  - `.accepted` — the user's `terms_of_service_id` equals the document's id: the workspace;
///  - `.unreadable` — the check ran and could not read an answer (transport, 5xx, a body that
///    cannot be decoded): **blocked**, never a silent workspace;
///  - `.unknown` — not asked yet (a process that has no provider wired, or the first frame of a
///    launch). Treated as "today's behaviour" by the gate, never as an acceptance.
enum TermsOfServiceState: Equatable, Sendable {
    case unknown
    case notRequired
    case pending(TermsOfServiceDocument)
    case accepted
    case unreadable(String)

    /// Whether the shell must show the blocking gate for this state.
    var isBlocking: Bool {
        switch self {
        case .pending, .unreadable: return true
        case .unknown, .notRequired, .accepted: return false
        }
    }

    var document: TermsOfServiceDocument? {
        if case .pending(let document) = self { return document }
        return nil
    }

    /// The reason a blocked gate is blocked, for copy and diagnostics (never the document text).
    var reason: String? {
        if case .unreadable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - The pure derivation

/// The auth layer's phase, independent of `AuthCoordinator`'s per-server object identity.
///
/// It exists so the gate rule can be a pure function the unit suite can exhaust: `AuthPhase` ×
/// `TermsOfServiceState` → `AuthGateDecision`. `AuthCoordinator.Phase` maps onto it one-to-one.
enum AuthPhase: Equatable, Sendable {
    /// No restore has resolved yet this run.
    case unresolved
    case signedIn
    case signedOut
    /// A stored session was rejected (401): re-auth, not a workspace.
    case expired
}

/// What the shell should render.
enum AuthGateDecision: Equatable, Sendable {
    case signedIn
    case signedOut
    /// Signed in, but the terms are outstanding (or could not be read): the blocking gate.
    case termsOfService
}

/// The one rule that decides whether a signed-in session may mount the workspace.
///
/// It is pure, total and has no I/O, so every branch the card names is a unit test rather than a
/// UI observation:
///
/// | phase          | TOS state                | decision        |
/// |----------------|--------------------------|-----------------|
/// | signedOut/expired | anything              | signedOut       |
/// | signedIn       | notRequired / accepted   | signedIn        |
/// | signedIn       | pending / unreadable     | termsOfService  |
/// | signedIn       | unknown                  | signedIn        |
///
/// `unreadable` fails **closed**: the check could not establish that the terms are accepted, and
/// the card is explicit that the alternative — a workspace whose every write the server refuses —
/// is the bug being fixed. `unknown` is the one intentional optimism, and it is only reachable
/// before the check has been asked for (see `AuthCoordinator.authState(for:)`, which additionally
/// refuses the optimistic window for a server whose last known verdict is pending).
enum TermsOfServiceGate {

    static func decide(phase: AuthPhase, terms: TermsOfServiceState) -> AuthGateDecision {
        switch phase {
        case .signedOut, .expired:
            return .signedOut
        case .unresolved, .signedIn:
            switch terms {
            case .notRequired, .accepted, .unknown:
                return .signedIn
            case .pending, .unreadable:
                return .termsOfService
            }
        }
    }

    /// The pending document the gate should render, if the decision is blocked by one.
    static func blockingDocument(phase: AuthPhase, terms: TermsOfServiceState) -> TermsOfServiceDocument? {
        guard decide(phase: phase, terms: terms) == .termsOfService else { return nil }
        return terms.document
    }
}

// MARK: - Reading the server

/// What the gate needs from one server. A seam so the unit suite can script every answer —
/// including the ones a fixture cannot produce cheaply (a 500, a body that decodes to nothing).
@MainActor
protocol TermsOfServiceProviding: AnyObject {
    /// The server's current document, or `nil` when the server says there is no custom TOS.
    func latestDocument() async throws -> TermsOfServiceDocument?
    /// The signed-in user, whose `termsOfServiceID` is the acceptance fact.
    func currentUser() async throws -> MMUser
    /// `POST /users/me/terms_of_service` with `{termsOfServiceId, accepted: true}`.
    func accept(documentID: String) async throws
}

/// The live provider for one server's session.
///
/// It goes through `AuthSession.client` on purpose: that is the client whose `onUnauthorized`
/// feeds the app's one re-auth path, so a 401 while checking the terms expires the session like
/// any other call (the rule `AuthCoordinator` states for every screen).
///
/// The acceptance comparison is upstream's `observeShowToS`: `user.termsOfServiceId !== <current>`.
/// The current id is the **document's** id (`GET /terms_of_service`), not the config's
/// `CustomTermsOfServiceId` — measured on 9.11.19, that config key is no longer in
/// `GET /config/client?format=old` at all, so a config-driven rule would never fire (see
/// `docs/t49-build-note.md` §2).
@MainActor
final class ServerTermsOfServiceAPI: TermsOfServiceProviding {

    private let session: AuthSession

    init(session: AuthSession) {
        self.session = session
    }

    func latestDocument() async throws -> TermsOfServiceDocument? {
        do {
            let document = try await session.client.get(TermsOfServiceDocument.self,
                                                        path: "/terms_of_service",
                                                        useETag: false)
            guard !document.id.isEmpty else {
                throw MMError.malformedResponse("terms_of_service carried no id")
            }
            return document
        } catch MMError.notFound {
            // 404: no custom terms on this server (TOS disabled, or no document published).
            // Measured on 9.11.19: an *accepted* user still gets `200` from this endpoint, so a
            // 404 can only mean "there is nothing to accept" — never "already accepted".
            return nil
        } catch MMError.client(let status, _) where status == 400 {
            // `api.create_terms_of_service.custom_terms_of_service_disabled`: feature off.
            return nil
        }
    }

    func currentUser() async throws -> MMUser {
        try await session.client.currentUser()
    }

    func accept(documentID: String) async throws {
        struct Body: Encodable {
            var termsOfServiceId: String
            var accepted: Bool
        }
        struct Reply: Decodable { var status: String }
        let reply = try await session.client.post(Reply.self,
                                                  path: "/users/me/terms_of_service",
                                                  body: Body(termsOfServiceId: documentID, accepted: true))
        guard reply.status == "OK" else {
            throw MMError.malformedResponse("accept terms_of_service: status \(reply.status)")
        }
    }
}
