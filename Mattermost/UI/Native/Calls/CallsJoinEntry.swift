// T44d — the channel header's "Join call" entry point (S33's entry surface).
//
// The web client puts the Calls button in the channel header and learns about a call from the
// socket. This app cannot use the socket for that (measured: the plugin's `call_start`/`call_end`
// frames never reach a plain authenticated member — `docs/t44d-build-note.md` §2), so the button
// is driven by the plugin's own REST answer (`GET …/calls/{channel_id}/active`), refreshed when the
// channel appears and then on a slow poll while the pane is open.
//
// The 20 s interval is a compromise stated rather than hidden: a shorter one is a per-pane request
// every few seconds against every open channel, and a call's *existence* is the only fact that needs
// refreshing — once the reader is in, participant deltas come from the socket.

import SwiftUI

struct CallsJoinEntry: View {
    let server: ServerConfig
    let channelID: String
    let channelName: String?

    @EnvironmentObject private var calls: CallsCoordinator
    @State private var presentation: CallsCallModel?
    @State private var isStarting = false

    private var isActive: Bool { calls.isCallActive(serverID: server.id, channelID: channelID) }

    private var refreshInterval: TimeInterval { CallsUITestHook.activeCallPollInterval }

    var body: some View {
        Group {
            if calls.isCallsAvailable(serverID: server.id) {
                // One entry point for both jobs, like upstream's header button: with a call already
                // running the plugin's `join` attaches this session to it, and with no call it
                // *creates* one. A button that only appeared once somebody else had started a call
                // would mean nobody could ever start one.
                Button {
                    guard !isStarting else { return }
                    isStarting = true
                    Task {
                        presentation = await calls.startCall(server: server,
                                                             channelID: channelID,
                                                             channelName: channelName)
                        isStarting = false
                    }
                } label: {
                    Label(isActive ? "Join call" : "Start call",
                          systemImage: isActive ? "phone.badge.waveform.fill" : "phone.fill")
                        .labelStyle(.iconOnly)
                }
                .disabled(isStarting)
                .accessibilityLabel(isActive ? "Join call" : "Start call")
                .accessibilityValue(isStarting ? "joining" : (isActive ? "active call" : "idle"))
                .accessibilityIdentifier("calls.joinButton")
            }
        }
        .task(id: channelID) {
            // Immediate check on appearance, then the slow poll. Cancelled with the view.
            while !Task.isCancelled {
                await calls.refreshActiveCall(server: server, channelID: channelID)
                let nanos = UInt64(max(1, refreshInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        .fullScreenCover(item: $presentation) { model in
            CallsSurfaceView(model: model)
        }
        .alert("Calls", isPresented: Binding(get: { calls.lastError != nil },
                                             set: { if !$0 { calls.clearError() } })) {
            Button("OK", role: .cancel) { calls.clearError() }
        } message: {
            Text(calls.lastError ?? "")
        }
    }
}

/// Launch-argument seams for this surface's UI tests (the same shape as `ChannelUITestHook`).
enum CallsUITestHook {
    /// `-uiTestCallsPollInterval <seconds>`: how often the join button re-asks the server. A live
    /// test that starts a call *after* the app is on screen needs a short interval; a person never
    /// sets it, and nothing else reads it.
    static var activeCallPollInterval: TimeInterval {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiTestCallsPollInterval"),
              args.indices.contains(index + 1),
              let seconds = Double(args[index + 1]),
              seconds > 0 else { return 20 }
        return seconds
    }
}
