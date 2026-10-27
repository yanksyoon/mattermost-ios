// T43's read-out in Settings: **which input is live**, and what each input has actually done this run.
//
// Why a settings row rather than a new screen: this card has no screen of its own — it is an input path,
// not a surface — so the honest "reachable in the running app" artefact is the shell's own state page. It
// shows real server facts, not fixtures: the mode the process resolved, how many servers' sockets are up,
// how many banners the socket path delivered or suppressed (with the reason), how many frames the web
// bridge was refused, and the last mention's channel, title and post id.
//
// Every number here is a counter over events that actually happened in this process, which is what makes
// the acceptance criterion checkable by eye: under the native input the web bridge shows
// `refused>0, accepted=0`, and under the shipped default it shows the reverse.

import SwiftUI

struct NotificationInputSection: View {
    @ObservedObject var path: NotificationPathStore
    @ObservedObject var feed: NativeNotificationFeed
    @ObservedObject var routing: NotificationInputRouting

    var body: some View {
        Section {
            row(title: "Mention input",
                value: path.mode.label,
                identifier: "notificationPath.mode",
                detail: path.isLaunchOverridden
                    ? "set by the -notificationPath launch argument"
                    : nil)

            LabeledContent {
                Text("\(routing.webPaneCount)")
                    .accessibilityIdentifier("notificationPath.webPanes")
            } label: {
                Text("Web view panes mounted")
            }

            LabeledContent {
                Text("\(routing.liveSocketCount)")
                    .accessibilityIdentifier("notificationPath.liveSockets")
            } label: {
                Text("Servers with a live socket")
            }

            LabeledContent {
                Text("\(routing.socketDelivered) delivered · \(routing.socketDropped) suppressed")
                    .accessibilityIdentifier("notificationPath.socket")
                    .accessibilityValue("delivered=\(routing.socketDelivered) "
                                        + "suppressed=\(routing.socketDropped) "
                                        + "mentions=\(routing.socketMentions) "
                                        + "posts=\(routing.socketPostsSeen)")
            } label: {
                Text("From the socket")
            }

            LabeledContent {
                Text("\(routing.bridgeAccepted) accepted · \(routing.bridgeRefused) refused")
                    .accessibilityIdentifier("notificationPath.bridge")
                    .accessibilityValue("accepted=\(routing.bridgeAccepted) "
                                        + "refused=\(routing.bridgeRefused)")
            } label: {
                Text("From the web view")
            }

            // T43-R (F2): whether the page **can** report at all. `window.desktop.notifyMention` is only
            // installed with `-desktopBridge` (off by default, because advertising it breaks the web
            // app's render), so `accepted=0` in the shipped configuration is structural, not a decision.
            // This row is what lets a live run say which of the two it measured.
            LabeledContent {
                Text(WebViewStore.desktopBridgeEnabled ? "installed" : "not installed")
                    .accessibilityIdentifier("notificationPath.pageBridge")
                    .accessibilityValue(WebViewStore.desktopBridgeEnabled ? "installed" : "not installed")
            } label: {
                Text("Page can report (window.desktop)")
            }

            if let record = feed.lastRecord {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.delivered ? "Last mention delivered" : "Last mention suppressed")
                    Text(record.channelLabel.isEmpty ? record.channelID : record.channelLabel)
                    Text(record.body.isEmpty ? record.title : record.body)
                        .font(.caption)
                    Text(record.outcome)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("notificationPath.lastMention")
                .accessibilityValue("post=\(record.postID) channel=\(record.channelID) "
                                    + "outcome=\(record.outcome)")
            } else {
                Text("No mention has arrived over the socket since launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notificationPath.lastMention")
                    .accessibilityValue("none")
            }
        } header: {
            Text("Mention notifications")
        } footer: {
            Text(footerText)
                .font(.caption)
        }
    }

    /// Which input is live, said in one sentence, and why.
    private var footerText: String {
        let live: String
        if routing.webPaneCount > 0 {
            live = "A web view is drawing this server's pane, so the page is the input: it is the only "
                + "side that knows which channel is on screen, and the socket stays silent so the same "
                + "mention cannot produce two banners."
        } else {
            live = "No web view is mounted, so the native socket is the input: it reads the server's own "
                + "`posted` event, and the page's report would be refused so the same mention cannot "
                + "produce two banners."
        }
        return "Which input tells the shell a mention happened. " + live
            + " The shipped default stays on the web view until T43's adversarial validation approves "
            + "the flip (-notificationPath socket proves it today)."
    }

    private func row(title: String, value: String, identifier: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                Text(value)
                    .accessibilityIdentifier(identifier)
                    .accessibilityValue(value)
            } label: {
                Text(title)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
