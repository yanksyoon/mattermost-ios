// S18 / T53 — the playback surfaces.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/components/files/video_file.tsx`
// (video inline, AVKit controls), `app/components/files/audio_file.tsx` (a compact row: play/pause,
// a progress bar, no screen takeover), `app/screens/gallery/` (full screen). Licence: Apache-2.0 —
// behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no upstream source copied.
//
// Three surfaces, one controller (`MediaPlaybackController`):
//   * `VideoPreviewView` — the single-file sheet's video. AVKit draws the picture; this file draws
//     the transport (play/pause, scrubber, position, full screen) so every control has a stable
//     accessibility identifier and the live test can assert a *state transition*, not a screenshot.
//     PiP is AVKit's own (`allowsPictureInPicturePlayback` + automatic start from inline), which is
//     the "if free" half of the card.
//   * `AudioAttachmentRowView` — a row inside the post: play/pause, a progress bar and the position.
//     No sheet, no takeover; the post stays where it is.
//   * `VideoAttachmentCell` — the row's poster. The server has no thumbnail for video (measured,
//     `scripts/t53_media_seed.py`: 400), so the client draws the first frame of the file it stages,
//     with a play badge. A file it will not stage draws a labelled plate instead of a bare glyph.
//
// Lifecycle is not left to SwiftUI's discretion: every surface calls `stop()` in `onDisappear`, the
// controller cancels its staging task with itself, and `MediaPlaybackCenter` pauses on resign-active
// and stops/releases on entering the background. Nothing autoplays.

import SwiftUI
import AVKit
import UIKit

// MARK: - AVKit surface

/// `AVPlayerViewController` as a SwiftUI view.
///
/// `showsPlaybackControls` is false inline because this file's transport bar sits directly below the
/// picture (one set of controls, every one identifiable). Full screen turns AVKit's own controls on,
/// which is where scrubbing, the skip buttons and the PiP button live for a full-size player.
struct VideoPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer?
    var showsPlaybackControls: Bool = false

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.videoGravity = .resizeAspect
        // PiP "if free": AVKit can move a playing item to a floating window and can start doing so
        // automatically when the app leaves the foreground. It is unavailable on some devices and
        // does nothing there — no custom PiP plumbing is worth the code for a shell feature.
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        if controller.showsPlaybackControls != showsPlaybackControls {
            controller.showsPlaybackControls = showsPlaybackControls
        }
    }
}

// MARK: - Video (single-file sheet)

struct VideoPreviewView: View {
    let attachment: PostAttachment
    let media: ChannelMedia

    @StateObject private var controller: MediaPlaybackController
    @State private var isFullScreen = false

    init(attachment: PostAttachment, media: ChannelMedia) {
        self.attachment = attachment
        self.media = media
        _controller = StateObject(wrappedValue: MediaPlaybackController(attachment: attachment,
                                                                       media: media))
    }

    var body: some View {
        VStack(spacing: 0) {
            surface
            transport
        }
        // Staging starts when the sheet opens; playback does not.
        .task { controller.prepare() }
        .onDisappear { controller.stop() }
        .fullScreenCover(isPresented: $isFullScreen) {
            fullScreenPlayer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentPreview.video")
    }

    private var surface: some View {
        ZStack {
            Color.black
            if let player = controller.player {
                VideoPlayerSurface(player: player)
            } else if case .failed(let message) = controller.phase {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                    Text(message)
                        .font(.scaled(12))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(20)
                .accessibilityIdentifier("attachmentPreview.video.error")
            } else {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Preparing video…")
                        .font(.scaled(12))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { controller.togglePlayback() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(!controller.isPrepared)
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("attachmentPreview.video.play")

                Slider(value: Binding(get: { controller.currentTime },
                                      set: { controller.seek(to: $0) }),
                       in: 0...max(0.1, controller.duration)) { editing in
                    controller.isScrubbing = editing
                }
                .disabled(!controller.isPrepared || controller.duration <= 0)
                .accessibilityLabel("Playback position")
                .accessibilityIdentifier("attachmentPreview.video.scrubber")

                Button { isFullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(controller.player == nil)
                .accessibilityLabel("Full screen")
                .accessibilityIdentifier("attachmentPreview.video.fullscreen")
            }

            HStack {
                Text(controller.clockLabel)
                    .font(.scaled(11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(controller.spokenPosition)
                    .accessibilityIdentifier("attachmentPreview.video.time")
                Spacer(minLength: 0)
                if case .failed = controller.phase, controller.player == nil {
                    Button("Retry") {
                        controller.stop()
                        controller.prepare()
                    }
                    .font(.scaled(11))
                    .accessibilityIdentifier("attachmentPreview.video.retry")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var fullScreenPlayer: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayerSurface(player: controller.player, showsPlaybackControls: true)
                .ignoresSafeArea()
            Button { isFullScreen = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(12)
            .accessibilityLabel("Exit full screen")
            .accessibilityIdentifier("attachmentPreview.video.exitFullScreen")
        }
        .onDisappear {
            // Leaving the full-screen presentation must not keep playing behind the sheet: the
            // reader asked to leave the big surface, not to end playback, so pause (not stop).
            controller.pause()
        }
    }
}

// MARK: - Audio (compact, in the row)

struct AudioAttachmentRowView: View {
    let attachment: PostAttachment
    let postID: String
    let media: ChannelMedia
    let state: AttachmentDownloadState
    let isInteractive: Bool
    let onDownload: () -> Void

    @StateObject private var controller: MediaPlaybackController

    init(attachment: PostAttachment,
         postID: String,
         media: ChannelMedia,
         state: AttachmentDownloadState,
         isInteractive: Bool,
         onDownload: @escaping () -> Void) {
        self.attachment = attachment
        self.postID = postID
        self.media = media
        self.state = state
        self.isInteractive = isInteractive
        self.onDownload = onDownload
        _controller = StateObject(wrappedValue: MediaPlaybackController(attachment: attachment,
                                                                       media: media))
    }

    private var prefix: String { "post.\(postID).attachment.\(attachment.id)" }

    private var subtitle: String {
        let base = attachment.audioRowDetail
        return [base, state.label].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { controller.togglePlayback() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(!isInteractive)
                .accessibilityLabel(controller.isPlaying ? "Pause \(attachment.name)" : "Play \(attachment.name)")
                .accessibilityValue(controller.spokenPosition)
                .accessibilityIdentifier("\(prefix).play")

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                        .font(.scaled(13, weight: .medium))
                        .mmLineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.scaled(11))
                            .foregroundStyle(.secondary)
                            .mmLineLimit(1)
                            .accessibilityIdentifier("\(prefix).subtitle")
                    }
                }
                Spacer(minLength: 0)

                if isInteractive && !attachment.isBlocked {
                    downloadButton
                }
            }

            if controller.isPrepared || controller.phase == .preparing {
                HStack(spacing: 8) {
                    // The progress bar is the compact player's own timeline (no sheet). It is also
                    // the VoiceOver value, so "how far in" is readable without the clock.
                    ProgressView(value: controller.progress)
                        .tint(Color.accentColor)
                        .accessibilityLabel("Playback progress")
                        .accessibilityValue(controller.spokenPosition)
                        .accessibilityIdentifier("\(prefix).progress")

                    Text(controller.clockLabel)
                        .font(.scaled(10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(controller.spokenPosition)
                        .accessibilityIdentifier("\(prefix).time")
                }
            }

            if case .failed(let message) = controller.phase {
                Text(message)
                    .font(.scaled(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(prefix).error")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .onDisappear { controller.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix).audioPlayer")
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch state {
        case .downloading(let fraction):
            ZStack {
                if let fraction {
                    CircularProgressView(fraction: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityLabel("Downloading")
            .accessibilityIdentifier("\(prefix).progress.download")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Saved to Downloads")
                .accessibilityIdentifier("\(prefix).saved")
        case .idle, .failed:
            Button(action: onDownload) {
                Image(systemName: state == .idle ? "arrow.down.circle" : "arrow.clockwise.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .idle ? "Download \(attachment.name)" : "Retry download")
            .accessibilityIdentifier("\(prefix).download")
        }
    }
}

// MARK: - Video poster cell

/// The row's video thumbnail: the file's first frame with a play badge.
///
/// 300 × 169 pt (16:9) — one cell at the widest bubble, matching the single-image cap, because a
/// video poster is the widest thing the section draws. The poster itself is a ≤600 px bitmap from
/// the staged file, so a 4K clip costs one downscaled frame, not a 4K frame.
struct VideoAttachmentCell: View {
    let attachment: PostAttachment
    let postID: String
    let media: ChannelMedia?
    let isInteractive: Bool
    let onOpen: () -> Void

    static let width: CGFloat = 300
    static let height: CGFloat = 169
    static let cornerRadius: CGFloat = 8

    @State private var poster: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    private var prefix: String { "post.\(postID).attachment.\(attachment.id)" }

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                } else {
                    plate
                }
                Color.black.opacity(poster == nil ? 0 : 0.08)
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.95))
                            .shadow(radius: 2)
                        if let duration = attachment.durationLabel {
                            Text(duration)
                                .font(.scaled(11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .task(id: attachment.id) { await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isInteractive ? [.isButton, .isImage] : .isImage)
        .accessibilityLabel(attachment.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(prefix)
    }

    private var accessibilityValue: String {
        let detail = [attachment.typeLabel, attachment.durationLabel, attachment.sizeLabel]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if didFail { return "\(detail). Poster unavailable, tap to play." }
        if poster != nil { return detail }
        return "\(detail). Loading poster."
    }

    private var plate: some View {
        ZStack {
            Color(.tertiarySystemFill)
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "video")
                        .font(.system(size: 22))
                    Text(attachment.name)
                        .font(.scaled(11))
                        .mmLineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard poster == nil, let media else { return }
        if let cached = media.posters.cachedPoster(for: attachment) {
            poster = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        let loaded = await media.posters.poster(for: attachment)
        guard !Task.isCancelled else { return }
        poster = loaded
        didFail = loaded == nil
    }
}

// MARK: - Audio inside the single-file sheet

/// The sheet's audio branch: the same compact row, widened. Audio normally never leaves the post
/// (that is the whole point of the row player); this exists so a host that opens an audio attachment
/// as a file still gets a player instead of a blank sheet.
struct AudioPreviewView: View {
    let attachment: PostAttachment
    let media: ChannelMedia

    var body: some View {
        VStack {
            AudioAttachmentRowView(attachment: attachment,
                                   postID: "preview",
                                   media: media,
                                   state: .idle,
                                   isInteractive: true,
                                   onDownload: {})
                .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
