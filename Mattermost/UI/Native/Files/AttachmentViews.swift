// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 — `app/components/files/files.tsx`
// (image grid + the rows below it), `app/components/files/image_file.tsx` (thumbnail with an overlay),
// `app/components/files/file.tsx` (the row: type icon, name, size), `app/components/files/file_icon.tsx`.
// Licence: Apache-2.0 — structure and behaviour ported with attribution per
// docs/THIRD_PARTY_NOTICES.md §15; no upstream source copied.
//
// The inline half of S18: what a post draws between its body and its reactions. Images are thumbnails
// in a grid (tap = open the gallery at that image); everything else is a row with a type icon, the
// server's own file name, its size and a download button (tap = open the preview, or, when there is no
// reader, the "not previewed" screen).
//
// Every state here is a *placeholder* that keeps the row's height: loading (`ProgressView` on a filled
// plate), failed (the row itself, with Retry) and blocked (a row that says so). A thumbnail never
// silently collapses to zero and never draws a broken-image glyph.

import SwiftUI

/// What a row may do with its attachments. Nil keeps the pre-T38 rendering: files are drawn, nothing
/// is pressable (a preview host, or the web render of the pane).
struct PostRowAttachmentActions {
    /// The per-file save state and the one download path (nil = no download affordance is drawn).
    var downloads: AttachmentDownloads?
    /// Open the full-screen gallery at one image of this post.
    var onOpenImage: (String) -> Void
    /// Open one file's preview (PDF/text/unsupported).
    var onOpenFile: (String) -> Void
}

/// One post's attachment section: image grid, then file rows, in the server's order.
struct AttachmentSectionView: View {
    let row: PostRowModel
    let imageStore: ChannelImageStore?
    var actions: PostRowAttachmentActions? = nil

    /// Images whose bytes did not arrive. Kept per row (not in the store) because a failure is a
    /// rendering fact, not a cache entry: the store must not remember "this failed" forever.
    @State private var failedImages: Set<String> = []

    private var section: AttachmentSection { AttachmentSection(row.attachments) }

    var body: some View {
        let split = section
        VStack(alignment: .leading, spacing: 6) {
            if !split.images.isEmpty {
                imageGrid(split.images)
            }
            ForEach(split.files) { attachment in
                AttachmentFileRowView(attachment: attachment,
                                      postID: row.id,
                                      state: actions?.downloads?.state(for: attachment.id) ?? .idle,
                                      isInteractive: actions != nil,
                                      onOpen: { actions?.onOpenFile(attachment.id) },
                                      onDownload: { actions?.downloads?.download(attachment) })
            }
        }
    }

    // MARK: Image grid

    private func imageGrid(_ images: [PostAttachment]) -> some View {
        let columns = AttachmentImageGrid.columnCount(for: images.count)
        let size = AttachmentImageGrid.cellSize(count: images.count,
                                                availableWidth: AttachmentImageGrid.singleMaxWidth)
        return VStack(alignment: .leading, spacing: AttachmentImageGrid.spacing) {
            ForEach(0..<AttachmentImageGrid.rowCount(for: images.count), id: \.self) { rowIndex in
                HStack(spacing: AttachmentImageGrid.spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = rowIndex * columns + column
                        if images.indices.contains(index) {
                            let attachment = images[index]
                            AttachmentImageCell(
                                attachment: attachment,
                                postID: row.id,
                                size: size,
                                imageStore: imageStore,
                                didFail: failedImages.contains(attachment.id),
                                isInteractive: actions != nil,
                                onRetry: {
                                    failedImages.remove(attachment.id)
                                },
                                onOpen: { actions?.onOpenImage(attachment.id) },
                                onDownload: { actions?.downloads?.download(attachment) })
                        }
                    }
                    if images.count % columns != 0, rowIndex == AttachmentImageGrid.rowCount(for: images.count) - 1 {
                        // Keep the last, short row left-aligned: a grid that stretches its final row
                        // makes one thumbnail look like a different size from the rest.
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("post.\(row.id).attachments")
    }
}

/// One inline thumbnail.
///
/// Three states, all the same size so the list does not jump:
///  * cached or loaded → the image, `scaledToFit` inside the cell;
///  * loading → a filled plate with a spinner (the "placeholder" the card asks for);
///  * failed → the file row for that image, with a retry. An image that cannot be fetched is still a
///    file the reader can download.
struct AttachmentImageCell: View {
    let attachment: PostAttachment
    let postID: String
    let size: CGSize
    let imageStore: ChannelImageStore?
    let didFail: Bool
    let isInteractive: Bool
    let onRetry: () -> Void
    let onOpen: () -> Void
    let onDownload: () -> Void

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if didFail {
                failedPlate
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height > 0 ? min(size.height, size.width == size.height ? size.height : size.height) : size.height)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isInteractive else { return }
            if image != nil { onOpen() }
            else if didFail { onRetry() }
        }
        .task(id: attachment.id) { await load() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isInteractive ? [.isButton, .isImage] : .isImage)
        .accessibilityLabel(attachment.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("post.\(postID).attachment.\(attachment.id)")
    }

    private var accessibilityValue: String {
        if didFail { return "\(attachment.typeLabel). Could not load the preview." }
        if image != nil { return "\(attachment.typeLabel), \(attachment.sizeLabel)" }
        return "\(attachment.typeLabel). Loading preview."
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var failedPlate: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
    }

    private func load() async {
        guard image == nil, !didFail, let imageStore else { return }
        if let cached = imageStore.cachedImage(for: attachment) {
            image = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        // `.task(id:)` is cancelled when the cell leaves the tree, and the store drops the waiter and
        // cancels the request — the bounded-load rule this card is measured on.
        let loaded = await imageStore.image(for: attachment)
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded
        }
    }
}

/// One non-image attachment: icon, name, `type · size · status`, and a download button.
struct AttachmentFileRowView: View {
    let attachment: PostAttachment
    let postID: String
    let state: AttachmentDownloadState
    let isInteractive: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void

    private var descriptor: FileTypeDescriptor { attachment.typeDescriptor }

    private var subtitle: String {
        let parts = [attachment.typeLabel, attachment.sizeLabel, state.label]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: attachment.symbolName)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isInteractive)
            .accessibilityIdentifier("post.\(postID).attachment.\(attachment.id)")

            if isInteractive && !attachment.isBlocked {
                downloadButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
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
            .accessibilityIdentifier("post.\(postID).attachment.\(attachment.id).progress")
            .accessibilityLabel("Downloading")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .accessibilityIdentifier("post.\(postID).attachment.\(attachment.id).saved")
                .accessibilityLabel("Saved to Downloads")
        case .idle, .failed:
            Button(action: onDownload) {
                Image(systemName: state == .idle ? "arrow.down.circle" : "arrow.clockwise.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .idle ? "Download \(attachment.name)" : "Retry download")
            .accessibilityIdentifier("post.\(postID).attachment.\(attachment.id).download")
        }
    }
}

/// A determinate ring for an in-flight download (the row's progress, without a text line per tick).
struct CircularProgressView: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
    }
}
