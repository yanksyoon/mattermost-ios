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
        .task(id: channelID) { startIfRequested() }
        .onReceive(calls.$pendingStarts) { _ in
            // The other half: an intent that arrives **after** this pane is already on screen (the
            // same conversation's profile opened again). `onReceive` and not `onChange`: the latter
            // compares against the value captured at the last body evaluation, and a pane rebuilt in
            // the same turn as the write loses that baseline — measured once as a join that simply
            // never ran. A publisher emission has no baseline to lose. Neither trigger is a task
            // identity that consumption can invalidate, so nothing here cancels the join it starts.
            startIfRequested()
        }
        .fullScreenCover(item: $presentation, onDismiss: {
            // The one dismissal rule: closing the surface (Leave, Close, a swipe down, or the pane
            // going away) leaves the call. `onDismiss` is what SwiftUI raises for a dismissal — a
            // content re-creation is not one, which is why this lives here and not in the surface's
            // own `onDisappear` (`CallsSurfaceView`'s header).
            Task { await calls.endCall() }
        }) { model in
            CallsSurfaceView(model: model)
        }
        .alert("Calls", isPresented: Binding(get: { calls.lastError != nil },
                                             set: { if !$0 { calls.clearError() } })) {
            Button("OK", role: .cancel) { calls.clearError() }
        } message: {
            Text(calls.lastError ?? "")
        }
    }

    /// Consume the profile's Call intent, if this pane is its target, and start the call — and
    /// present it — from the pane, never from inside the sheet the row was tapped in.
    ///
    /// Deliberately **not** a `.task(id:)`: the pending value is part of what consumption changes, so
    /// an id that carries it is invalidated by the very act of consuming it, and SwiftUI then cancels
    /// the in-flight task. Measured: the join failed with `MMError.cancelled` while the plugin-version
    /// request was still out, so no call was ever created (`build/logs/t5449-c3-ui-call2.log`). A
    /// plain `Task` started here is owned by nobody, so the next view update cannot cancel it.
    /// A failure surfaces through `startCall`'s `lastError` alert above, the surface's one error path.
    private func startIfRequested() {
        guard presentation == nil, !isStarting else { return }
        guard calls.consumeStart(serverID: server.id, channelID: channelID) else { return }
        isStarting = true
        Task {
            presentation = await calls.startCall(server: server,
                                                 channelID: channelID,
                                                 channelName: channelName)
            isStarting = false
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
