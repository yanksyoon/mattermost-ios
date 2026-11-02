// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/forgot_password/index.tsx (`isEmail`, "Reset Your Password", the sent state),
//        app/screens/login/form.tsx (the fields the auth card offers),
//        app/queries/servers/terms_of_service.ts (the config keys the TOS gate reads).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The decoded-property policy object is this repo's own.

import Foundation

// MARK: - The public config document

// `GET /api/v4/config/client?format=old` answers a flat object of name → value, decoded into the
// transport's existing `JSONValue` (`Core/MM/MMJSON.swift`). On 9.11 the values are **strings**
// (`"8"`, `"true"`); every read below therefore goes through a string-tolerant helper rather than
// assuming a JSON boolean/number. Nothing is decided by looking at the raw body.

// MARK: - The server's own policy

/// What the sign-up and sign-in screens need to obey **the server's** rules rather than ours.
///
/// Every field is decoded from `GET /config/client?format=old` by name, with a documented default
/// for a key an older server does not send:
///
///  - `PasswordMinimumLength` → `8` when absent (the server's own default);
///  - `PasswordMaximumLength` → `72` when absent (the server's hard cap, `model.PasswordMaximumLength`);
///  - `EnableSignUpWithEmail` / `EnableUserCreation` → `true` when absent (an older server that
///    does not publish the key still offers email sign-up, which is what today's screen does);
///  - `PasswordEnableForgotLink` → `true` when absent;
///  - `TermsOfServiceLink` → `nil` when absent (the gate then shows only the document text);
///  - `CustomTermsOfServiceEnabled` / `EnableCustomTermsOfService` → `nil` when absent, i.e.
///    "not stated". 9.11 does **not** publish this key (measured: see `docs/t49-build-note.md` §2),
///    so it is never allowed to decide the gate on its own.
struct ServerAuthPolicy: Equatable, Sendable {

    var termsOfServiceEnabled: Bool?
    var termsOfServiceLink: URL?
    var allowsEmailSignUp: Bool
    var allowsUserCreation: Bool
    var allowsPasswordReset: Bool
    var minimumPasswordLength: Int
    var maximumPasswordLength: Int
    var requiresUppercase: Bool
    var requiresLowercase: Bool
    var requiresNumber: Bool
    var requiresSymbol: Bool

    static let defaultMinimumPasswordLength = 8
    /// Mattermost's hard cap (`model.PasswordMaximumLength`), not a per-server setting.
    static let defaultMaximumPasswordLength = 72

    init(termsOfServiceEnabled: Bool? = nil,
         termsOfServiceLink: URL? = nil,
         allowsEmailSignUp: Bool = true,
         allowsUserCreation: Bool = true,
         allowsPasswordReset: Bool = true,
         minimumPasswordLength: Int = ServerAuthPolicy.defaultMinimumPasswordLength,
         maximumPasswordLength: Int = ServerAuthPolicy.defaultMaximumPasswordLength,
         requiresUppercase: Bool = false,
         requiresLowercase: Bool = false,
         requiresNumber: Bool = false,
         requiresSymbol: Bool = false) {
        self.termsOfServiceEnabled = termsOfServiceEnabled
        self.termsOfServiceLink = termsOfServiceLink
        self.allowsEmailSignUp = allowsEmailSignUp
        self.allowsUserCreation = allowsUserCreation
        self.allowsPasswordReset = allowsPasswordReset
        self.minimumPasswordLength = minimumPasswordLength
        self.maximumPasswordLength = maximumPasswordLength
        self.requiresUppercase = requiresUppercase
        self.requiresLowercase = requiresLowercase
        self.requiresNumber = requiresNumber
        self.requiresSymbol = requiresSymbol
    }

    /// Decode the client config by **named property**. Unknown keys are ignored; absent keys take
    /// the documented defaults (see the type comment).
    init(clientConfig: [String: JSONValue]) {
        func flexibleBool(_ value: JSONValue?) -> Bool? {
            switch value {
            case .bool(let flag)?: return flag
            case .string(let text)?:
                switch text.lowercased() {
                case "true", "1": return true
                case "false", "0": return false
                default: return nil
                }
            case .number(let number)?: return number != 0
            default: return nil
            }
        }
        func flexibleString(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let text)?: return text.isEmpty ? nil : text
            case .number(let number)?:
                return number == number.rounded() ? String(Int(number)) : String(number)
            default: return nil
            }
        }
        func bool(_ keys: String...) -> Bool? {
            for key in keys {
                if let value = flexibleBool(clientConfig[key]) { return value }
            }
            return nil
        }
        func int(_ keys: String...) -> Int? {
            for key in keys {
                if let value = clientConfig[key]?.intValue { return value }
            }
            return nil
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = flexibleString(clientConfig[key]) { return value }
            }
            return nil
        }

        let minimum = int("PasswordMinimumLength") ?? Self.defaultMinimumPasswordLength
        let maximum = int("PasswordMaximumLength") ?? Self.defaultMaximumPasswordLength
        // A server that sent nonsense still gets a sane, enforced window.
        minimumPasswordLength = max(1, min(minimum, maximum))
        maximumPasswordLength = max(maximum, minimumPasswordLength)

        termsOfServiceEnabled = bool("EnableCustomTermsOfService", "CustomTermsOfServiceEnabled")
        termsOfServiceLink = string("TermsOfServiceLink").flatMap(URL.init(string:))
        allowsEmailSignUp = bool("EnableSignUpWithEmail") ?? true
        allowsUserCreation = bool("EnableUserCreation") ?? true
        allowsPasswordReset = bool("PasswordEnableForgotLink") ?? true
        requiresUppercase = bool("PasswordRequireUppercase") ?? false
        requiresLowercase = bool("PasswordRequireLowercase") ?? false
        requiresNumber = bool("PasswordRequireNumber") ?? false
        requiresSymbol = bool("PasswordRequireSymbol") ?? false
    }

    /// Whether the sign-in screen may offer "Create an account".
    var offersSignUp: Bool { allowsEmailSignUp && allowsUserCreation }

    /// The sentence under the password field on the sign-up form: the server's own numbers, not a
    /// hard-coded constant.
    var passwordPolicyCopy: String {
        var parts: [String] = ["Use \(minimumPasswordLength)–\(maximumPasswordLength) characters."]
        var classes: [String] = []
        if requiresUppercase { classes.append("an uppercase letter") }
        if requiresLowercase { classes.append("a lowercase letter") }
        if requiresNumber { classes.append("a number") }
        if requiresSymbol { classes.append("a symbol") }
        if !classes.isEmpty {
            parts.append("The server also requires " + Self.list(classes) + ".")
        }
        return parts.joined(separator: " ")
    }

    /// The first rule this password breaks, in the server's own terms, or `nil` when it passes.
    /// Pure, so the form's disabled-button rule and its inline error share one implementation.
    func passwordProblem(_ password: String) -> String? {
        if password.isEmpty { return "Enter a password." }
        if password.count < minimumPasswordLength {
            return "Password must be at least \(minimumPasswordLength) characters."
        }
        if password.count > maximumPasswordLength {
            return "Password must be at most \(maximumPasswordLength) characters."
        }
        if requiresUppercase, password.rangeOfCharacter(from: .uppercaseLetters) == nil {
            return "Password must include an uppercase letter."
        }
        if requiresLowercase, password.rangeOfCharacter(from: .lowercaseLetters) == nil {
            return "Password must include a lowercase letter."
        }
        if requiresNumber, password.rangeOfCharacter(from: .decimalDigits) == nil {
            return "Password must include a number."
        }
        if requiresSymbol, password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil {
            return "Password must include a symbol."
        }
        return nil
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

// MARK: - Reading it from the server

/// `GET /api/v4/config/client?format=old` — public, unauthenticated, cached by ETag.
///
/// It is not part of `AuthSession`: the sign-in screen runs before there is a session, and the
/// request carries no credential (a 401 here would be a server bug, not an expiry).
@MainActor
final class ServerAuthPolicyAPI {

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func load() async throws -> ServerAuthPolicy {
        let raw = try await client.get([String: JSONValue].self,
                                       path: "/config/client",
                                       query: [URLQueryItem(name: "format", value: "old")],
                                       requiresAuth: false)
        return ServerAuthPolicy(clientConfig: raw)
    }
}

/// What the sign-up and reset flows need from one server. A seam so the view models are unit
/// testable without a transport.
@MainActor
protocol AccountServicing: AnyObject {
    /// The public policy this server publishes (password rules, sign-up availability, TOS link).
    func policy() async throws -> ServerAuthPolicy

    /// `POST /api/v4/users` — create an email/password account.
    /// - Returns: the created user's id.
    func createAccount(email: String, password: String) async throws -> String

    /// `POST /api/v4/users/password/reset/send`.
    func requestPasswordReset(email: String) async throws
}

/// The live implementation: the same `/api/v4` URL shaping, TLS decision and typed errors as every
/// other call, with no credential attached (both endpoints are public).
///
/// The client is built per call from a factory rather than held, because the screens that own this
/// service outlive any one `APIClient` and the factory is the only place that can surface a
/// certificate prompt into the auth layer. A construction failure (an invalid configured URL) is
/// reported like any other typed error instead of crashing a sheet's initialiser.
@MainActor
final class ServerAccountAPI: AccountServicing {

    private let clientFactory: () throws -> APIClient

    init(clientFactory: @escaping () throws -> APIClient) {
        self.clientFactory = clientFactory
    }

    func policy() async throws -> ServerAuthPolicy {
        try await ServerAuthPolicyAPI(client: try clientFactory()).load()
    }

    func createAccount(email: String, password: String) async throws -> String {
        struct Body: Encodable {
            var email: String
            var password: String
        }
        let user = try await clientFactory().post(MMUser.self,
                                                  path: "/users",
                                                  body: Body(email: email, password: password),
                                                  requiresAuth: false)
        guard !user.id.isEmpty else {
            throw MMError.malformedResponse("POST /users carried no id")
        }
        return user.id
    }

    func requestPasswordReset(email: String) async throws {
        struct Body: Encodable { var email: String }
        struct Reply: Decodable { var status: String }
        let reply = try await clientFactory().post(Reply.self,
                                                   path: "/users/password/reset/send",
                                                   body: Body(email: email),
                                                   requiresAuth: false)
        guard reply.status == "OK" else {
            throw MMError.malformedResponse("password reset: status \(reply.status)")
        }
    }
}

// MARK: - Email

/// Upstream's `isEmail` (`app/utils/helpers.ts`), which the forgot-password form uses before it
/// sends anything: one `@`, something on both sides, and a dot-with-something in the domain.
enum EmailAddress {
    static func isValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let domain = parts[1]
        guard let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) < domain.endIndex
    }
}
