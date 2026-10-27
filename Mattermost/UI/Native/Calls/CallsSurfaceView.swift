// T44d — the native call surface (S33): participant tiles, the reader's own mute/hand/leave
// controls, and the states a call really has (joining, connected, reconnecting, no microphone,
// ended).
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (Apache-2.0),
// `app/products/calls/screens/call_screen/call_screen.tsx` (header state, control bar, per-session
// cards) and `…/participant_card.tsx` (tile: name, "(you)", muted, hand, host). Reimplemented in
// SwiftUI per docs/THIRD_PARTY_NOTICES.md §22 — no upstream source copied.
//
// **Screen share is deliberately absent.** A native share needs the ReplayKit Broadcast Upload
// Extension target of T44e *and* a recorded licence/App-Review position (a human decision), so the
// control is not drawn at all rather than drawn inert — docs/t44d-build-note.md §5. The same rule
// governs the **camera** control: `CallsVideoCapability` says this build cannot carry video, so
// `CallsControlSet.showsCamera` is false and no camera button exists. A participant *sharing* from
// another client still gets a marker on their tile, because the call's audio still plays.

import SwiftUI

struct CallsSurfaceView: View {
    @ObservedObject var model: CallsCallModel
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 12)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let message = model.microphoneMessage {
                banner(message, systemImage: "mic.slash", identifier: "calls.micBanner")
            }
            if let error = model.error {
                banner(error, systemImage: "exclamationmark.triangle", identifier: "calls.error")
            }
            controls
        }
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callsSurface")
        .onDisappear {
            // Leaving the screen leaves the call: a background session with no UI is the one state
            // a reader cannot reason about (and it holds the audio session).
            Task { await model.leave() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(model.channelName ?? "Call")
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("calls.channelName")
            HStack(spacing: 8) {
                Text(model.phase.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("calls.state")
                    .accessibilityValue(model.phase.statusText)
                if model.phase.isLive {
                    Text(model.durationLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("calls.timer")
                        .accessibilityValue(model.durationLabel)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.phase.isTerminal {
            endedState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.participants) { participant in
                        CallsParticipantTile(participant: participant)
                    }
                }
                .padding()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calls.participants")
            .overlay {
                if model.participants.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for the call…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("calls.participants.waiting")
                }
            }
        }
    }

    private var endedState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "phone.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.phase.statusText)
                .font(.title3)
                .accessibilityIdentifier("calls.ended")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 20) {
            if model.phase.isTerminal {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("calls.closeButton")
            } else {
                // Mute is drawn (disabled) when the microphone grant is missing, with the banner
                // saying why: a reader whose mic was refused still needs to see the call's mute
                // state. That is upstream's behaviour, and it is not the same as an inert control.
                controlButton(title: model.controls.muteTitle,
                              systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill",
                              enabled: model.controls.canToggleMute,
                              identifier: "calls.muteButton",
                              value: model.isMuted ? "muted" : "unmuted") {
                    await model.toggleMute()
                }
                controlButton(title: model.controls.handTitle,
                              systemImage: model.hasRaisedHand ? "hand.raised.fill" : "hand.raised",
                              enabled: model.controls.canToggleHand,
                              identifier: "calls.handButton",
                              value: model.hasRaisedHand ? "raised" : "lowered") {
                    await model.toggleHand()
                }
                Button(role: .destructive) {
                    Task {
                        await model.leave()
                        dismiss()
                    }
                } label: {
                    Label("Leave", systemImage: "phone.down.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("calls.leaveButton")
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func controlButton(title: String,
                               systemImage: String,
                               enabled: Bool,
                               identifier: String,
                               value: String,
                               action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

// MARK: - Tile

/// One participant: avatar, name, and the state the tile draws (hand, mute/voice, host, sharing).
struct CallsParticipantTile: View {
    let participant: CallsParticipant

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(participant.isMuted ? Color.secondary.opacity(0.25) : Color.accentColor.opacity(0.28))
                Text(participant.initials)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                // The account's own picture. Below the speaking ring on purpose: the ring is state,
                // the picture is identity, and state stays visible.
                AvatarPicture(userID: participant.userID, size: 64)
                if participant.isSpeaking && !participant.isMuted {
                    Circle().stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .frame(width: 64, height: 64)

            Text(participant.label)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 4) {
                if participant.hasRaisedHand {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }
                Image(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(participant.isMuted ? Color.secondary : Color.green)
                if participant.isHost {
                    Image(systemName: "crown.fill").foregroundStyle(.yellow)
                }
                if participant.isSharingScreen {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.blue)
                }
            }
            .font(.caption2)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(participant.label)
        .accessibilityValue(participant.stateDescription)
        .accessibilityIdentifier("calls.tile.\(participant.userID)")
    }
}
