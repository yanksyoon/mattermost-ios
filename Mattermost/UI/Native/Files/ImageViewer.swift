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

struct AttachmentGalleryView: View {
    let target: AttachmentGalleryTarget
    let imageStore: ChannelImageStore?
    var downloads: AttachmentDownloads?
    let onClose: () -> Void

    @State private var page: Int
    @State private var shareItem: SharePayload?
    @State private var failure: String?

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
                    .font(.system(size: 12))
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
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(gallery.counterLabel(min(page, max(0, gallery.images.count - 1))))
                    .font(.system(size: 11))
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
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .accessibilityLabel("Save to Downloads")
            .accessibilityIdentifier("attachmentGallery.save")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func shareCurrent() {
        guard let attachment = current, let imageStore else { return }
        Task {
            guard let data = await imageStore.originalData(for: attachment) else {
                failure = "This image could not be loaded to share."
                return
            }
            guard let url = AttachmentShare.temporaryFile(named: attachment.name, data: data) else {
                failure = "This image could not be staged for sharing."
                return
            }
            shareItem = SharePayload(url: url)
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

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else if didFail {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("This image could not be loaded.")
                        .font(.system(size: 13))
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
        .task(id: "\(attachment.id)-\(isCurrent)") {
            guard isCurrent, image == nil, !didFail else { return }
            await load()
        }
        .accessibilityIdentifier("attachmentGallery.page.\(attachment.id)")
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

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maximumZoom
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear

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
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        private let parent: ZoomableImageView

        init(_ parent: ZoomableImageView) {
            self.parent = parent
            super.init()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

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
