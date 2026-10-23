import SwiftUI

/// Add/edit server form. Native counterpart of desktop `NewServerModal` / `ConfigureServer`
/// (parity row `NewServerModal` -> `ServerFormView`, `ServerHub` -> `ServerFormModel`). The URL
/// field is validated live against the server's `/api/v4/system/ping` + `/api/v4/config/client`
/// endpoints (via `ServerFormModel`/`ServerURLValidator`); Save is gated on a valid probe, and the
/// display name auto-fills from the probed site name. Status: native, P1/P3.
struct ServerFormView: View {
    let serverStore: ServerStore
    let viewStore: ViewStore?
    /// When non-nil the sheet edits this server; when nil it adds a new one.
    let editing: ServerConfig?

    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ServerFormModel
    @State private var errorText: String?

    init(serverStore: ServerStore, viewStore: ViewStore? = nil, editing: ServerConfig? = nil) {
        self.serverStore = serverStore
        self.viewStore = viewStore
        self.editing = editing

        let formID: ServerFormModel.ServerFormID = editing.map { .edit($0.id) } ?? .new
        _model = StateObject(wrappedValue: ServerFormModel(formID: formID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Display name", text: $model.name)
                        .textInputAutocapitalization(.words)
                    TextField("Server URL", text: $model.urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .onChange(of: model.urlText) { _, newValue in
                            model.urlDidChange(urlText: newValue)
                        }
                }
                if let message = model.urlMessage {
                    Section {
                        Label(message.text, systemImage: icon(for: message.tone))
                            .font(.footnote)
                            .foregroundStyle(color(for: message.tone))
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!model.canSave)
                }
            }
        }
        .onAppear {
            // Prime the form for edit mode: prefill and validate the stored URL.
            if let editing {
                model.name = editing.name
                if model.urlText.isEmpty {
                    model.urlText = editing.url.absoluteString
                    Task { await model.validateCurrent() }
                }
            }
        }
    }

    private func icon(for tone: ServerFormModel.Tone) -> String {
        switch tone {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }

    private func color(for tone: ServerFormModel.Tone) -> Color {
        switch tone {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func save() {
        do {
            // Trust the validated/normalized URL from validation when present; else fall back to
            // ServerURL.normalize (the pre-validation guard) for robustness.
            let urlText: String
            if let validated = model.validationResult?.validatedURL, !validated.isEmpty {
                urlText = validated
            } else {
                urlText = model.urlText
            }
            let normalizedURL = try ServerURL.normalize(urlText)
            var config = editing ?? ServerConfig(name: trimmed(model.name), url: normalizedURL)
            config.name = trimmed(model.name)
            config.url = normalizedURL

            // Duplicate guard (belt-and-suspenders; validation already flags URL_EXISTS).
            if editing == nil, serverStore.containsServer(withSameHostAs: config) {
                errorText = "That server is already configured."
                return
            }

            if config.name.isEmpty { config.name = config.url.host ?? config.url.absoluteString }

            if editing != nil {
                serverStore.update(config)
                // If the edited server's URL changed, point its live webview + session at the new
                // origin (desktop `configureServer` re-launches the server with the new URL); a
                // name-only edit leaves the running session untouched.
                if let store = viewStore?.view(forServerID: config.id),
                   store.url != config.url {
                    store.load(config.url)
                }
            } else if let added = serverStore.add(config) {
                viewStore?.setPrimary(added.id)
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}