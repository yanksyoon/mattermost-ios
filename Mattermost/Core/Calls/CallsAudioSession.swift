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

        // Not manual: the engine starts and stops audio with the call, and libwebrtc's ADM needs to
        // be free to activate while the track exists.
        session.useManualAudio = false
        session.isAudioEnabled = true

        let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setActive(true)
        MMLog.info("MMCalls", "audio session: playAndRecord/voiceChat, active="
            + "\(session.isActive), input=\(session.inputAvailable)")
    }

    func deactivate() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
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
