// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_files/channel_files.tsx (the list, its empty state and its paging),
//        app/components/files/file.tsx (the row: icon, name, type · size), app/screens/image_viewer
//        (the image a thumbnail opens), and app/screens/pdf_viewer / code for the single-file preview.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied.
//
// T52 reuses T38's preview and gallery **screens** rather than growing a second file renderer: an
// image row opens `AttachmentGalleryView` with the channel's images as its pages, and every other row
// opens `AttachmentPreviewView` (PDF, bounded text, or the safe "not previewed" screen). The rows here
// are the list's own (`channelInfo.files.row.<id>`) so the live test can compare them with the
// server's answer one by one.
//
// The list's source is measured in `ChannelFilesModels.swift`'s header: `POST
// /teams/{tid}/files/search` with `in:<channel-name>`, because `GET /channels/{id}/files` is 404 on
// 9.11.19 and `channel_id:` is not an operator its file search understands.

import SwiftUI

/// The sheet a file row opens. One item-bound sheet, so a tap cannot be swallowed by a second
/// presentation in the same view (the rule `ChannelListSheet` states for the post list).
private enum ChannelFilesSheet: Identifiable {
    case preview(AttachmentPreviewTarget)
    case gallery(AttachmentGalleryTarget)

    var id: String {
        switch self {
        case .preview(let target): return "preview.\(target.id)"
        case .gallery(let target): return "gallery.\(target.id)"
        }
    }
}

struct ChannelFilesView: View {
    /// The list's model, **built by the caller before the push** so this screen never has an "no model
    /// yet, and never will be" state. T52-R3 measured that state: the destination pushed and sat on a
    /// spinner forever because the model had not been created, which is indistinguishable from a slow
    /// first page — the caller now creates it from the row's own tap.
    @ObservedObject var files: ChannelFilesViewModel
    /// The channel's id, used to key the gallery target.
    let channelID: String
    /// T38's image store and download coordinator, handed down by the channel pane. Nil leaves the
    /// rows readable but the preview a little poorer (no inline thumbnails) and download absent —
    /// the same degradation T38 documents for a host that offers no write surface.
    var imageStore: ChannelImageStore?
    var downloads: AttachmentDownloads?

    @State private var sheet: ChannelFilesSheet?

    var body: some View {
        Group {
            content(files)
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if files.phase == .idle { await files.load() }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .preview(let target):
                AttachmentPreviewView(target: target,
                                      imageStore: imageStore,
                                      downloads: downloads,
                                      onClose: { sheet = nil })
            case .gallery(let target):
                AttachmentGalleryView(target: target,
                                      imageStore: imageStore,
                                      downloads: downloads,
                                      onClose: { sheet = nil })
            }
        }
    }

    @ViewBuilder
    private func content(_ files: ChannelFilesViewModel) -> some View {
        switch files.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("channelInfo.files.loading")
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("channelInfo.files.error")
                Button("Try again") {
                    Task { await files.load() }
                }
                .accessibilityIdentifier("channelInfo.files.retry")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if files.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No files in this channel")
                        .font(.headline)
                        .accessibilityIdentifier("channelInfo.files.empty")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(files.rows) { row in
                            Button {
                                open(row)
                            } label: {
                                ChannelFileRowView(attachment: row.attachment,
                                                   download: downloads?.state(for: row.id) ?? .idle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("channelInfo.files.row.\(row.id)")
                            .swipeActions(edge: .trailing) {
                                if let downloads, !row.attachment.isBlocked {
                                    Button {
                                        downloads.download(row.attachment)
                                    } label: {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                    .tint(Color.accentColor)
                                }
                            }
                            .onAppear {
                                if row.id == files.rows.last?.id {
                                    Task { await files.loadMore() }
                                }
                            }
                        }
                        if files.isLoadingMore {
                            ProgressView()
                                .accessibilityIdentifier("channelInfo.files.more")
                        }
                    } header: {
                        Text(files.rows.count == 1 ? "1 file" : "\(files.rows.count) files")
                            .accessibilityIdentifier("channelInfo.files.count")
                    } footer: {
                        if let banner = files.banner {
                            Text(banner)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("channelInfo.files.banner")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await files.load() }
            }
        }
    }

    private func open(_ row: ChannelFileRow) {
        if row.isInlineImage {
            let target = AttachmentGalleryTarget(postID: "channelFiles.\(channelID)",
                                                 attachments: files.imageAttachments,
                                                 startFileID: row.id)
            if target.gallery != nil {
                sheet = .gallery(target)
                return
            }
        }
        sheet = .preview(AttachmentPreviewTarget(postID: row.postID, attachment: row.attachment))
    }
}

/// One row: the file's icon, its name, and `type · size` — the same three facts T38's attachment row
/// draws, with this list's own identifier.
struct ChannelFileRowView: View {
    let attachment: PostAttachment
    let download: AttachmentDownloadState

    private var subtitle: String {
        [attachment.typeLabel, attachment.sizeLabel, download.label]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.symbolName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24)
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
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([attachment.name, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
