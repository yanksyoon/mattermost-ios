import Foundation
import Combine

/// Persistent download journal — native counterpart of the desktop `downloadsManager`'s in
/// memory history list backed by `JsonFileManager`. Parity row:
/// `DownloadsManager`/`JsonFileManager` -> `DownloadHistory` (`@Published [DownloadRecord]`,
/// persisted via `AppPreferences`/`UserDefaults`). Status: native, Phase 2.
///
/// This is the *data* store only: it owns the observable list and its persistence. The
/// orchestration — performing downloads, handling the webview's `WKDownloadDelegate`, wiring
/// Share/Files — lives in `DownloadWorker`, which composes this history. Keeping the two apart
/// lets the journal, its JSON round-trip and its trimming rules be unit-tested without any
/// network/webview machinery, exactly like `ServerStore` vs. `ViewStore`.
@MainActor
final class DownloadHistory: ObservableObject {

    /// Newest first — this is the list the Downloads dropdown renders.
    @Published private(set) var records: [DownloadRecord] = []

    /// The `UserDefaults` key the journal is persisted under. Stable across releases.
    static let storageKey = AppPreferences.Keys.downloadsHistory
    /// Default hard cap on retained history rows (oldest dropped first). Mirrors the desktop
    /// drawer's bounded list rather than an unbounded file. T11 exposes this as the
    /// `AppSettings.downloadHistoryLimit` Stepper; the static keeps the pre-T11 default for
    /// callers/tests that never touch settings.
    static let maxRecords = 50

    /// The effective retention cap for THIS journal. Initialised from
    /// `AppSettings.downloadHistoryLimit` (setting -> instance, default 50) so the Settings
    /// Stepper is a real knob, not a stored-but-ignored number. `setMaxRecords` re-trims live.
    private(set) var maxRecords: Int

    private let preferences: AppPreferences

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        let stored = preferences.get(Int.self, forKey: AppSettings.Keys.downloadHistoryLimit)
            ?? Self.maxRecords
        self.maxRecords = min(max(stored, AppSettings.downloadHistoryLimitRange.lowerBound),
                              AppSettings.downloadHistoryLimitRange.upperBound)
        load()
    }

    /// Apply a new retention cap and immediately drop the oldest rows beyond it (no-op when
    /// the cap grows). Persists the new cap so a relaunch reads the same limit. The app wires
    /// this to `AppSettings.$downloadHistoryLimit` (MattermostApp), so a Stepper change in
    /// SettingsView re-trims the open journal live.
    func setMaxRecords(_ limit: Int) {
        let clamped = min(max(limit, AppSettings.downloadHistoryLimitRange.lowerBound),
                          AppSettings.downloadHistoryLimitRange.upperBound)
        guard clamped != maxRecords else { return }
        maxRecords = clamped
        preferences.set(clamped, forKey: AppSettings.Keys.downloadHistoryLimit)
        publish(records)
    }

    // MARK: Queries

    func find(id: UUID) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    // MARK: Mutations (each persists)

    /// Insert a new record at the front of the journal. When the record carries a `source`
    /// URL, a re-download of the same source replaces the prior in-flight entry instead of
    /// duplicating it (desktop download dedup — the design's "download dedup" test target).
    func add(_ record: DownloadRecord) {
        var next = records
        if !record.source.isEmpty {
            next = next.filter { $0.source != record.source || $0.id == record.id }
        }
        next.insert(record, at: 0)
        publish(next)
    }

    /// Persist an in-place state change (progress tick, completion, cancel, error, retry).
    func update(_ record: DownloadRecord) {
        guard let idx = records.firstIndex(where: { $0.id == record.id }) else {
            add(record)
            return
        }
        var next = records
        next[idx] = record
        publish(next)
    }

    func remove(id: UUID) {
        publish(records.filter { $0.id != id })
    }

    /// Drop every terminal record, keeping only in-flight downloads.
    func clearFinished() {
        publish(records.filter { $0.state == .downloading })
    }

    // MARK: Persistence

    private func publish(_ next: [DownloadRecord]) {
        var bounded = next
        while bounded.count > maxRecords { bounded.removeLast() }
        records = bounded
        save()
    }

    private func save() {
        preferences.set(records, forKey: Self.storageKey)
    }

    private func load() {
        records = preferences.get([DownloadRecord].self, forKey: Self.storageKey) ?? []
    }
}