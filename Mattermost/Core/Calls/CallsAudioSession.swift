// The Calls audio-session owner.
//
// Today WebKit owns `AVAudioSession` (the webview's `getUserMedia` sets the category). A native
// engine has to own it instead — `.playAndRecord` / `.voiceChat` is the configuration a VoIP call
// needs, and without it the mic is not routed, the receiver/speaker choice is wrong and a Bluetooth
// headset is not picked up (docs/t44-build-note.md §3.1).
//
// `RTCAudioSession` is used rather than `AVAudioSession.sharedInstance()` directly because WebRTC
// keeps its own balanced activation count: going around it leaves the engine recording from a
// session it believes is inactive.

import AVFoundation
import Foundation
@preconcurrency import WebRTC

/// The seam, so the engine's lifecycle is testable without touching the real audio session.
protocol CallsAudioSessionControlling: Sendable {
    /// Take the session for a call: `.playAndRecord`, `.voiceChat`, active, audio enabled.
    func activateForCall() throws
    /// Give it back (call ended / call failed).
    func deactivate()
    /// The category/mode the session is in, for diagnostics (`"playAndRecord/voiceChat"`).
    func currentConfiguration() -> String
}

struct SystemCallsAudioSession: CallsAudioSessionControlling {

    func activateForCall() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }

        // **Manual** audio: the app owns activation, and libwebrtc's ADM only starts/stops its audio
        // unit through `isAudioEnabled`. Measured necessity (T44d live run, simulator 18.3.1): with
        // `useManualAudio = false` the ADM activates the session itself on top of this call, and the
        // RemoteIO unit it then initialises can deadlock against another in-process AudioToolbox
        // client — `AQIONodeManager` was held by a UIKit UI-sound renderer while
        // `AURemoteIO::Initialize` waited, the RPC timed out and AudioToolbox **aborted the app**
        // (`AudioToolboxCore::_ReportRPCTimeout` → `abort`). Manual audio is also what
        // react-native-webrtc does on iOS, i.e. what the upstream mobile client runs.
        session.useManualAudio = true

        // Category and activation **before** audio is enabled: `isAudioEnabled = true` makes the ADM
        // start its audio unit immediately, and starting it against a session that is not yet active
        // is a second way to land in that audio-server stall.
        //
        // `.allowBluetooth` only: a voice call wants HFP. `.allowBluetoothA2DP` is output-only and
        // Apple documents the pair as mutually exclusive; asking for both can make the system retry
        // the route/unit setup.
        let options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setActive(true)
        session.isAudioEnabled = true
        MMLog.info("MMCalls", "audio session: playAndRecord/voiceChat, active="
            + "\(session.isActive), input=\(session.inputAvailable)")
    }

    func deactivate() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        // Order matters with manual audio: stop the ADM's audio unit first (`isAudioEnabled = false`),
        // then hand the session back. Deactivating while the unit still runs is what races another
        // AudioToolbox client for `AQIONodeManager` (see `activateForCall`).
        session.isAudioEnabled = false
        do {
            try session.setActive(false)
        } catch {
            // A deactivation failure is not actionable during teardown; the OS reclaims the session.
            MMLog.debug("MMCalls", "audio session deactivate failed: \(error)")
        }
    }

    func currentConfiguration() -> String {
        let session = RTCAudioSession.sharedInstance()
        return "\(session.category)/\(session.mode)"
    }
}
