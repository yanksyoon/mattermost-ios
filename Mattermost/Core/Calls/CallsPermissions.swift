// Capture permission for a native Calls engine.
//
// The Info.plist strings (`NSMicrophoneUsageDescription`, `NSCameraUsageDescription`) are necessary
// but not sufficient for a *native* engine: WebRTC does not prompt for you, so the app must ask
// before it starts (docs/t44-build-note.md §3.1). A denied grant must become a visible state — "no
// mic" — instead of a call that silently sends silence.
//
// `AVCaptureDevice.requestAccess` is the same API WKWebView's `getUserMedia` ends up using, so a
// grant the user gave the webview applies here and vice versa. The request is bounded by a timeout
// because a headed prompt nobody answers (a headless `xcodebuild test`, an unattended CI machine)
// would otherwise block the caller forever — a state the caller can act on beats a hang.

import AVFoundation
import Foundation

/// The microphone grant, as a value the UI can render.
enum CallsMicrophonePermission: Equatable, Sendable {
    /// Asked and answered: the app may capture.
    case granted
    /// Asked and answered: the user (or a policy) said no. Surface it; do not pretend to send audio.
    case denied
    /// A supervising policy forbids it (Screen Time / MDM parental controls) — the user cannot
    /// change it in Settings, so the UI copy differs from `.denied`.
    case restricted
    /// Not answered within the request window. Treat as "no audio yet", not as a decision.
    case undetermined

    var canCaptureAudio: Bool { self == .granted }
}

/// The seam. Tests inject a fake so no test ever opens a TCC prompt.
protocol CallsPermissionRequesting: Sendable {
    func requestMicrophone(timeout: TimeInterval) async -> CallsMicrophonePermission
    func currentMicrophonePermission() -> CallsMicrophonePermission
}

extension CallsPermissionRequesting {
    func requestMicrophone() async -> CallsMicrophonePermission {
        await requestMicrophone(timeout: 10)
    }
}

/// The system implementation.
struct SystemCallsPermissions: CallsPermissionRequesting {

    func currentMicrophonePermission() -> CallsMicrophonePermission {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestMicrophone(timeout: TimeInterval) async -> CallsMicrophonePermission {
        // Only an unanswered status is worth prompting for; a previous answer is final (asking again
        // returns the same value without a prompt, which would only add latency).
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: break
        @unknown default: return .undetermined
        }

        return await withTaskGroup(of: CallsMicrophonePermission?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
                .mapGrant()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            // First answer wins: the grant callback, or the timeout.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .undetermined
        }
    }

    static func map(_ status: AVAuthorizationStatus) -> CallsMicrophonePermission {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}

private extension Bool {
    func mapGrant() -> CallsMicrophonePermission { self ? .granted : .denied }
}
