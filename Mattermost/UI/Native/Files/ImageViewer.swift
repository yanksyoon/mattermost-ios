// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/screens/gallery/`
// (`gallery.tsx` paging, `image_viewer.tsx` zoom/pan, `footer.tsx` share + save) and
// `app/components/files/image_file.tsx` (the thumbnail that opens it).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied.
//
// The full-screen half of S18: one post's images, paged horizontally, each zoomable, with Share and
// Save. It is presented as a sheet (`.sheet(item:)` from the channel list, the same single presentation
// point T35/T37 use) and it is **not** a navigation destination: opening an image must not lose the
// reader's place in the channel.
//
// Zoom is a `UIScrollView` and not a `MagnificationGesture`: a gesture-driven scale loses the pan
// bounds and springs back, while the scroll view gives pinch, pan, double-tap and rubber-banding for
// free — and it is what the RN gallery's platform image viewer does underneath.

import SwiftUI
import UIKit

/// A file staged for the system share sheet (`UIActivityViewController` wants a URL, not bytes).
struct SharePayload: Identifiable {
    let url: URL
    var id: URL { url }
}

/// `-uiTestExposeGalleryDiagnostics` publishes what the gallery is *doing* as accessibility values:
/// the current page's zoom scale (and the highest it ever reached) and what the last Share staged.
///
/// Gated on a launch argument, exactly like `ChannelUITestHook`, `ScrollGeometrySeam` and the media
/// seams: a build a person launches cannot reach this code. The values are a scale and a SHA-256
/// prefix — a measurement, not the bytes.
enum AttachmentGalleryDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestExposeGalleryDiagnostics")
    }

    /// `current=1.00 peak=4.00`. Two numbers, not one: a double-tap animates, so a test that reads
    /// `current` too early sees the scale halfway there; `peak` is what "it zoomed to the cap" means,
    /// and `current` is what "it went back" means.
    static func zoomValue(current: CGFloat, peak: CGFloat) -> String {
        String(format: "current=%.2f peak=%.2f", current, peak)
    }
}

struct AttachmentGalleryView: View {
    let target: AttachmentGalleryTarget
    let imageStore: ChannelImageStore?
    var downloads: AttachmentDownloads?
    let onClose: () -> Void

    @State private var page: Int
    @State private var shareItem: SharePayload?
    @State private var failure: String?
    /// What the last Share handed the sheet (`AttachmentShare.Staged`), or nil before the first one.
    @State private var staged: AttachmentShare.Staged?

    init(target: AttachmentGalleryTarget,
         imageStore: ChannelImageStore?,
         downloads: AttachmentDownloads? = nil,
         onClose: @escaping () -> Void) {
        self.target = target
        self.imageStore = imageStore
        self.downloads = downloads
        self.onClose = onClose
        _page = State(initialValue: target.startIndex)
    }

    private var gallery: AttachmentGallery? { target.gallery }

    private var current: PostAttachment? {
        guard let gallery, gallery.images.indices.contains(page) else { return nil }
        return gallery.images[page]
    }

    var body: some View {
        Group {
            if let gallery {
                VStack(spacing: 0) {
                    header(gallery)
                    Divider()
                    TabView(selection: $page) {
                        ForEach(Array(gallery.images.enumerated()), id: \.element.id) { index, attachment in
                            AttachmentGalleryPage(attachment: attachment,
                                                  postID: target.postID,
                                                  imageStore: imageStore,
                                                  isCurrent: index == page)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .background(Color(.systemBackground))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("attachmentGallery")
            } else {
                Text("There are no images to show.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("attachmentGallery.empty")
            }
        }
        .sheet(item: $shareItem) { payload in
            ActivityView(items: [payload.url])
        }
        .overlay(alignment: .bottom) {
            if let failure {
                Text(failure)
                    .font(.scaled(12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("attachmentGallery.error")
            }
        }
    }

    // MARK: Header

    private func header(_ gallery: AttachmentGallery) -> some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("attachmentGallery.close")

            VStack(alignment: .leading, spacing: 1) {
                Text(current?.name ?? "")
                    .font(.scaled(14, weight: .semibold))
                    .mmLineLimit(1)
                    .truncationMode(.middle)
                Text(gallery.counterLabel(min(page, max(0, gallery.images.count - 1))))
                    .font(.scaled(11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("attachmentGallery.counter")
            }
            Spacer(minLength: 0)

            Button { shareCurrent() } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .accessibilityLabel("Share image")
            .accessibilityIdentifier("attachmentGallery.share")

            Button { saveCurrent() } label: {
                Image(systemName: downloads?.state(for: current?.id ?? "") == .done
                      ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.scaled(17))
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .accessibilityLabel("Save to Downloads")
            .accessibilityIdentifier("attachmentGallery.save")

            if AttachmentGalleryDiagnostics.isEnabled {
                shareSeam
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The `-uiTestExposeGalleryDiagnostics` share seam: a four-point clear square that names the file
    /// the last Share staged and the digest of the bytes in it, so a live case can compare what the
    /// sheet was handed with what the server actually stores (the downsampled bitmap would not match).
    private var shareSeam: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 4, height: 4)
            .accessibilityElement()
            .accessibilityLabel("Share staged report")
            .accessibilityValue(staged?.summary ?? "none")
            .accessibilityIdentifier("attachmentGallery.share.staged")
    }

    // MARK: Actions

    private func shareCurrent() {
        guard let attachment = current, let imageStore else { return }
        Task {
            switch await AttachmentShareFlow.stage(attachment, from: imageStore) {
            case .success(let stagedShare):
                staged = stagedShare
                shareItem = SharePayload(url: stagedShare.url)
            case .failure(let refusal):
                staged = nil
                failure = refusal.message
            }
        }
    }

    private func saveCurrent() {
        guard let attachment = current else { return }
        if downloads?.download(attachment) == nil, downloads?.state(for: attachment.id).isActive == false {
            failure = "This image could not be downloaded."
        }
    }
}

/// One page of the gallery: the image, a loading state that keeps its frame, and a retry on failure.
struct AttachmentGalleryPage: View {
    let attachment: PostAttachment
    let postID: String
    let imageStore: ChannelImageStore?
    /// Only the page on screen loads: `TabView` keeps its neighbours alive, and three 2048² bitmaps for
    /// a swipe the reader has not made is exactly the unbounded growth this card is measured on.
    let isCurrent: Bool

    @State private var image: UIImage?
    @State private var didFail = false
    /// The scale on screen and the highest it has reached — only fed when the diagnostics seam is on.
    @State private var zoom: CGFloat = 1
    @State private var peakZoom: CGFloat = 1

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image, onZoomChange: zoomReport)
            } else if didFail {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .scaledSymbol(22)
                        .foregroundStyle(.secondary)
                    Text("This image could not be loaded.")
                        .font(.scaled(13))
                        .foregroundStyle(.secondary)
                    Button("Retry") { didFail = false; reload() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("attachmentGallery.page.\(attachment.id).retry")
                }
                .accessibilityIdentifier("attachmentGallery.page.\(attachment.id).error")
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("attachmentGallery.page.\(attachment.id).loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if AttachmentGalleryDiagnostics.isEnabled {
                zoomSeam
            }
        }
        .task(id: "\(attachment.id)-\(isCurrent)") {
            guard isCurrent, image == nil, !didFail else { return }
            await load()
        }
        // The page is the addressable unit of the gallery: one stable id per file, so a case can name
        // the page it pinched rather than "the second scroll view on screen".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentGallery.page.\(attachment.id)")
    }

    /// The `-uiTestExposeGalleryDiagnostics` zoom seam, four points in the page's top-right corner:
    /// `current=…` is the scale on screen now, `peak=…` the highest it has ever been on this page.
    private var zoomSeam: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 4, height: 4)
            .accessibilityElement()
            .accessibilityLabel("Zoom report")
            .accessibilityValue(AttachmentGalleryDiagnostics.zoomValue(current: zoom, peak: peakZoom))
            .accessibilityIdentifier("attachmentGallery.page.\(attachment.id).zoom")
    }

    /// Nil unless the seam is on: a shipping build does no per-frame work for a test's benefit.
    private var zoomReport: ((CGFloat, CGFloat) -> Void)? {
        guard AttachmentGalleryDiagnostics.isEnabled else { return nil }
        return { current, peak in
            zoom = current
            peakZoom = peak
        }
    }

    private func reload() {
        Task { await load() }
    }

    private func load() async {
        guard let imageStore else { didFail = true; return }
        let loaded = await imageStore.galleryImage(for: attachment)
        guard !Task.isCancelled else { return }
        if let loaded { image = loaded } else { didFail = true }
    }
}

/// A pinch/pan/double-tap zoomable image, backed by `UIScrollView`.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var maximumZoom: CGFloat = 4
    /// Reports `(current, peak)` on every zoom change. Nil in a shipping build: the gallery passes it
    /// only when `-uiTestExposeGalleryDiagnostics` is on.
    var onZoomChange: ((CGFloat, CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maximumZoom
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        context.coordinator.onZoomChange = onZoomChange

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.onZoomChange = onZoomChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        /// The highest scale this page has reached. Kept here, not in the observer, so it survives the
        /// SwiftUI state updates a zoom animation would otherwise coalesce.
        private(set) var peakScale: CGFloat = 1
        var onZoomChange: ((CGFloat, CGFloat) -> Void)?
        private let parent: ZoomableImageView

        init(_ parent: ZoomableImageView) {
            self.parent = parent
            super.init()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            report(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            report(scrollView)
        }

        private func report(_ scrollView: UIScrollView) {
            peakScale = max(peakScale, scrollView.zoomScale)
            onZoomChange?(scrollView.zoomScale, peakScale)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / parent.maximumZoom,
                              height: scrollView.bounds.height / parent.maximumZoom)
            let rect = CGRect(x: point.x - size.width / 2,
                              y: point.y - size.height / 2,
                              width: size.width,
                              height: size.height)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}
