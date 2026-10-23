import Foundation
import SwiftUI
import Combine

/// Native counterpart of desktop `ServerHub.handleServerURLValidation` + the `NewServerModal`
/// validation state machine (`src/app/serverHub.ts`, `src/renderer/components/NewServerModal`).
///
/// Owns the add/edit-server form's URL validation: debounces URL edits (mirrors the desktop 1s
/// `setTimeout`), runs `ServerURLValidator`, exposes the resulting `URLValidationStatus` + a
/// human message, auto-fills the display name from the server's probed site name when the user
/// hasn't typed one, and reports whether the form may be saved.
///
/// Parity row: `ServerHub` (add/edit server IPC + validation) -> `ServerFormModel` + `ServerURLValidator`.
/// Status: native, P1/P3.
@MainActor
final class ServerFormModel: ObservableObject {

    @Published var name = ""
    @Published var urlText = ""
    @Published private(set) var validationResult: URLValidationResult?
    @Published private(set) var isValidating = false

    private let validator: ServerURLValidator
    private var debounceTask: Task<Void, Never>?
    private var formID: ServerFormID

    enum ServerFormID: Hashable {
        case new
        case edit(UUID)
    }

    init(validator: ServerURLValidator = ServerURLValidator(),
         formID: ServerFormID = .new) {
        self.validator = validator
        self.formID = formID
    }

    var currentServerID: UUID? {
        if case .edit(let id) = formID { return id }
        return nil
    }

    /// True when the URL is empty or unparseable — the desktop's "URL is required / not formatted"
    /// states. Save must be disabled.
    var isURLBlocked: Bool {
        guard let result = validationResult else { return true }
        return result.status == .missing || result.status == .invalid || result.status == .notMattermost
    }

    /// Whether Save may be clicked: a name is present and the URL validated to a savable state.
    var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard validationResult != nil else { return false }
        guard !isValidating else { return false }
        return !isURLBlocked
    }

    /// Auto-fill the display name once the probe succeeds and the user hasn't typed one.
    var suggestedName: String? { validationResult?.serverName }

    /// A human-readable message for the current validation state (desktop `getServerURLMessage`).
    var urlMessage: (tone: Tone, text: String)? {
        if isValidating {
            return (tone: .info, text: "Validating…")
        }
        guard let result = validationResult else { return nil }
        switch result.status {
        case .missing:
            return (tone: .error, text: "URL is required.")
        case .invalid:
            return (tone: .error, text: "URL is not formatted correctly.")
        case .urlExists:
            let who = result.existingServerName.map { "\"\($0)\"" } ?? "another server"
            return (tone: .warning, text: "A server named \(who) with the same Site URL already exists.")
        case .insecure:
            return (tone: .warning, text: "Your server URL is potentially insecure. For best results, use a URL with the HTTPS protocol.")
        case .notMattermost:
            return (tone: .warning, text: "The server URL provided does not appear to point to a valid Mattermost server. Please verify the URL and check your connection.")
        case .urlNotMatched:
            let v = result.serverVersion.map { " Server version: \($0)." } ?? ""
            return (tone: .warning, text: "The server URL does not match the configured Site URL on your Mattermost server.\(v)")
        case .urlUpdated:
            let v = result.serverVersion.map { " Server version: \($0)." } ?? ""
            return (tone: .info, text: "The server URL provided has been updated to match the configured Site URL on your Mattermost server.\(v)")
        case .basicAuthRequired:
            return (tone: .warning, text: "This server requires basic authentication. You will be prompted to enter your username and password when you connect.")
        case .preAuthRequired:
            return (tone: .warning, text: "This server requires an authentication secret. You will be prompted to enter it when you connect.")
        case .clientCertRequired:
            return (tone: .warning, text: "This server requires that you select a certificate. You will be prompted to select a certificate when you connect.")
        case .magicLink, .ok:
            let v = result.serverVersion.map { " Server version: \($0)." } ?? ""
            return (tone: .success, text: "Server URL is valid.\(v)")
        }
    }

    enum Tone { case info, success, warning, error }

    /// Schedule a debounced validation (mirrors desktop's 1s `setTimeout` that cancels on each edit).
    func urlDidChange(urlText: String) {
        self.urlText = urlText
        validationResult = nil
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.validateCurrent()
        }
    }

    /// Run validation immediately (used on the initial edit-mode load and on save).
    func validateCurrent() async {
        isValidating = true
        defer { isValidating = false }
        let result = await validator.validate(rawURL: urlText, currentServerID: currentServerID)
        validationResult = result
        if suggestedName != nil, name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = suggestedName ?? name
        }
    }
}

extension Color {
    static let formTone: [ServerFormModel.Tone: Color] = [
        .info: .secondary,
        .success: .green,
        .warning: .orange,
        .error: .red,
    ]
}