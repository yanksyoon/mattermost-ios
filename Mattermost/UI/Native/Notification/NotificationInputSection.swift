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
            Text("Which input tells the shell a mention happened. " + path.mode.label
                 + ": the native socket reads the server's own `posted` event, and while it is live the "
                 + "web view's report is refused so the same mention cannot produce two banners. The "
                 + "shipped default stays on the web view until T43's adversarial validation approves the "
                 + "flip (-notificationPath socket proves it today).")
                .font(.caption)
        }
    }

    private func row(title: String, value: String, identifier: String,
                     detail: String?) -> some View {
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
