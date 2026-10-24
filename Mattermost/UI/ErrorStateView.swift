import SwiftUI

/// Native port of the desktop renderer error cluster (parity row: `ConnectionError` /
/// `IncompatibleError` / `Error` -> `ErrorStateView` + `RetryButton`, design §4d).
///
/// The desktop composes a generic `ErrorView` (header / subHeader / bullets / contactAdmin /
/// errorInfo) out of two concrete screens:
///   - `ConnectionErrorView`  — "Couldn't connect to this server" + troubleshooting bullets
///     (clear cache and reload, check network, verify URL) + "contact your admin".
///   - `IncompatibleErrorView` — "Incompatible server version" + downgrade bullet.
///
/// On iOS the shell cannot open a browser window or "downgrade the desktop app" the way
/// Electron can, so those desktop hyperlinks map to honest native analogues:
///   - "clear the cache and reload" -> `onClearCacheAndReload` (native `WKWebsiteDataStore`
///     wipe + reload; wired by `WebViewStore.clearCacheAndReload`).
///   - "Try opening {url} in a browser" / "Verify that the URL is correct" -> `onOpenExternal`
///     (UIApplication open the URL in Safari).
///
/// Copy strings mirror the desktop `FormattedMessage` defaults exactly (pinned by tests).
struct ErrorStateView: View {

    /// Desktop `appName` interpolation (`defaultMessage` uses {appName} a lot).
    var appName: String = "Mattermost"

    /// The server URL the user was connecting to (desktop `url` prop).
    var url: URL?

    /// The underlying macOS/WebKit error (desktop `errorInfo`, shown as technical info).
    var error: Error?

    /// Desktop's retry affordance (the renderer's `onRetry`/native error page reload).
    var onRetry: () -> Void = {}

    /// Desktop's "Try to clear the cache and reload" link handler.
    var onClearCacheAndReload: () -> Void = {}

    /// Desktop's "Try opening {url} in a browser window" / "Verify that the URL is correct"
    /// link handler.
    var onOpenExternal: () -> Void = {}

    /// Headline. Defaults to the connection-failure copy (desktop `ConnectionErrorView`); callers
    /// whose failure is not a connection failure override it — e.g. the native shell's pane when the
    /// route it is showing belongs to a server that has since been removed.
    var title: String = "Couldn't connect to this server"

    /// The first paragraph. `nil` keeps the connection-failure wording that explains the retry loop.
    var detail: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text(title)
                .font(.headline)

            Text(detail ?? "We're having trouble connecting to this \(appName) server. We'll keep trying to establish a connection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Please try the following steps if this issue persists:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                bulletRow(icon: "arrow.triangle.2.circlepath") {
                    Button("Try to clear the cache and reload. This may fix the issue.", action: onClearCacheAndReload)
                        .foregroundStyle(.tint)
                }
                bulletRow(icon: "wifi") {
                    Text("Ensure your device is connected to your network.")
                }
                bulletRow(icon: "link") {
                    Button("Verify that the URL \(url?.absoluteString ?? "") is correct.", action: onOpenExternal)
                        .foregroundStyle(.tint)
                }
                bulletRow(icon: "safari") {
                    if let url {
                        Button("Try opening \(url.absoluteString) in a browser.", action: onOpenExternal)
                            .foregroundStyle(.tint)
                    } else {
                        Text("Try opening the server address in a browser.")
                    }
                }
            }
            .font(.footnote)

            Text("If the issue persists, please contact your admin.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            RetryButton(action: onRetry)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bulletRow(icon: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compatibility entry point kept for existing callers: connection-style error with a
    /// retry action (desktop `ConnectionErrorView` default). Cache/browser links default to
    /// the same retry (a reload is the closest native "clear and try again" without
    /// destructive cache wiping every retry).
    init(error: Error?, url: URL? = nil, title: String = "Couldn't connect to this server",
         detail: String? = nil, onRetry: @escaping () -> Void) {
        self.error = error
        self.url = url
        self.title = title
        self.detail = detail
        self.onRetry = onRetry
        self.onClearCacheAndReload = onRetry
        self.onOpenExternal = onRetry
    }

    /// Full-feature init used by ContentView once cache-clearing is wired.
    init(appName: String = "Mattermost",
         url: URL? = nil,
         error: Error? = nil,
         onRetry: @escaping () -> Void,
         onClearCacheAndReload: @escaping () -> Void = {},
         onOpenExternal: @escaping () -> Void = {}) {
        self.appName = appName
        self.url = url
        self.error = error
        self.onRetry = onRetry
        self.onClearCacheAndReload = onClearCacheAndReload
        self.onOpenExternal = onOpenExternal
    }
}

/// Native counterpart of desktop `IncompatibleErrorView` (`ErrorView` subclass). The desktop
/// tells users to downgrade the Desktop App; on iOS the app ships via the App Store, so the
/// honest parallel is "contact your admin to upgrade this Mattermost server" (the desktop's
/// own contactAdmin line), and the downgrade hyperlink maps to opening the server's URL
/// externally.
struct IncompatibleErrorStateView: View {
    var appName: String = "Mattermost"
    var url: URL?
    var onOpenExternal: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 44))
                .foregroundStyle(.red)

            Text("Incompatible server version")
                .font(.headline)

            Text("The \(appName) Server you are accessing is incompatible with this version of the \(appName) app. To connect to this server, please try the following:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.app")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(.top, 1)
                if let url {
                    Button("Open \(url.absoluteString) in a browser to check for a compatible client.", action: onOpenExternal)
                        .foregroundStyle(.tint)
                } else {
                    Text("Open the server in a browser to check for a compatible client.")
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("If the issue persists, contact your \(appName) Administrator or IT department to upgrade this \(appName) Server.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native retry button (desktop error views' reload affordance; parity `ErrorStateView` +
/// `RetryButton`). Rendered as the prominent action under every error screen.
struct RetryButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("errorRetryButton")
    }
}

#Preview {
    ErrorStateView(error: nil) {}
}
