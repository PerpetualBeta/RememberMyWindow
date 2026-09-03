import Foundation

/// Durable home for the live layout.
///
/// The live layout has been tracked in memory since auto-save was taken out of
/// `LayoutStore`: full-store rewrites during a drag caused excess disk activity,
/// and mixing transient state into the saved snapshots caused clutter and edge
/// cases. Nothing here goes back on either of those decisions.
///
/// - It writes its **own file**, so a window drag never touches `layouts.json`
///   and never appears in the saved-snapshot dictionary.
/// - It coalesces far more slowly than the AX tracker, and takes a **forced
///   flush** on terminate, sleep and log-out so the last state before a
///   shutdown is the one kept.
/// - It keeps a short **ring** rather than one slot, and refuses to record a
///   capture whose window count has collapsed, so closing everything before a
///   meeting cannot become the layout you restore to.
struct AutoSaveEntry: Codable, Identifiable {
    var id: UUID = UUID()
    let capturedAt: Date
    let screenKey: String
    let readableScreenKey: String?
    let records: [WindowRecord]

    var windowCount: Int { records.count }
}

struct AutoSaveFile: Codable {
    /// Newest first.
    var entries: [AutoSaveEntry] = []
}

@MainActor
final class AutoSaveStore: ObservableObject {

    // MARK: - Policy

    /// Enough history to step back past a bad capture, few enough that the file
    /// stays small and the UI can show them all without a scroller.
    static let ringCapacity = 5

    /// The live tracker settles in seconds because the UI follows it. Durability
    /// does not need that: nothing reads this file until the next launch, so the
    /// only thing a short interval buys is disk writes.
    static let coalescingInterval: TimeInterval = 90

    /// A capture is rejected when the window count falls to this fraction of the
    /// last recorded one or below. Chosen rather than an absolute drop because
    /// losing 3 of 4 windows matters and losing 3 of 30 does not.
    static let collapseFraction = 0.5

    // MARK: - State

    @Published private(set) var entries: [AutoSaveEntry] = []
    /// Set when the file existed but could not be read. Writing is refused
    /// while true, for the same reason `WindowManager.persist()` refuses.
    @Published private(set) var isUnreadable = false

    var latest: AutoSaveEntry? { entries.first }

    private let fileURL: URL
    private var pending: AutoSaveEntry?
    private var lastWrite: Date?
    /// Guarantees the settled arrangement reaches disk. See `armTrailingFlush`.
    private var trailingTimer: Timer?
    private var log: (String) -> Void

    init(directory: URL, log: @escaping (String) -> Void = { _ in }) {
        self.fileURL = directory.appendingPathComponent("auto-layout.json")
        self.log = log
        load()
    }

    // MARK: - Recording

    /// Offers a capture. Held in memory and written only when the coalescing
    /// interval has passed, unless `force` is set.
    func record(records: [WindowRecord],
                screenKey: String,
                readableScreenKey: String?,
                now: Date = Date(),
                force: Bool = false) {
        guard !records.isEmpty else {
            log("auto-save: ignoring an empty capture")
            return
        }
        if let reason = collapseReason(newCount: records.count) {
            log("auto-save: \(reason)")
            return
        }

        pending = AutoSaveEntry(capturedAt: now,
                                screenKey: screenKey,
                                readableScreenKey: readableScreenKey,
                                records: records)

        if force || lastWrite == nil || now.timeIntervalSince(lastWrite!) >= Self.coalescingInterval {
            flush(now: now)
        } else {
            armTrailingFlush(from: now)
        }
    }

    /// Writes the pending capture once the coalescing interval has run out.
    ///
    /// Throttling on the leading edge alone loses the arrangement the user
    /// actually settled on. Move six windows and stop: the first move writes,
    /// the rest coalesce, and then nothing more arrives to trigger the write
    /// that would record where they ended up. Observed holding a half-finished
    /// arrangement on disk for over three minutes while the settled one sat in
    /// memory, and it would have held it indefinitely.
    ///
    /// The fire time is derived from `lastWrite`, not from now, so re-arming on
    /// every capture keeps aiming at the same instant rather than pushing the
    /// write further out. That keeps the one-write-per-interval promise intact
    /// and still guarantees the last state lands within one interval.
    private func armTrailingFlush(from now: Date) {
        guard let lastWrite else { return }
        let due = lastWrite.addingTimeInterval(Self.coalescingInterval)
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(withTimeInterval: max(due.timeIntervalSince(now), 0),
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    /// Writes whatever is pending. Called on terminate, sleep and log-out, so
    /// the state at shutdown is the state kept.
    func flush(now: Date = Date()) {
        trailingTimer?.invalidate()
        trailingTimer = nil
        guard let entry = pending else { return }
        guard !isUnreadable else {
            log("auto-save: refusing to write over a file that could not be read")
            return
        }
        pending = nil
        entries.insert(entry, at: 0)
        if entries.count > Self.ringCapacity {
            entries.removeSubrange(Self.ringCapacity...)
        }
        lastWrite = now
        write()
    }

    /// Nil when the capture is acceptable, otherwise why it was rejected.
    func collapseReason(newCount: Int) -> String? {
        guard let last = latest else { return nil }   // nothing to compare against
        guard last.windowCount > 0 else { return nil }
        let floor = Double(last.windowCount) * Self.collapseFraction
        guard Double(newCount) <= floor else { return nil }
        return "rejected a capture of \(newCount) window(s) against \(last.windowCount) recorded — a collapse, not an arrangement"
    }

    // MARK: - Disk

    private func write() {
        do {
            let data = try JSONEncoder().encode(AutoSaveFile(entries: entries))
            try data.write(to: fileURL, options: .atomic)
            log("auto-save: wrote \(entries.first?.windowCount ?? 0) window(s), \(entries.count) in ring")
        } catch {
            log("auto-save: write failed — \(error.localizedDescription)")
        }
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            isUnreadable = true
            log("auto-save: \(fileURL.lastPathComponent) could not be read — \(error.localizedDescription)")
            return
        }
        do {
            entries = try JSONDecoder().decode(AutoSaveFile.self, from: data).entries
            log("auto-save: loaded \(entries.count) entr(ies)")
        } catch {
            isUnreadable = true
            log("auto-save: \(fileURL.lastPathComponent) could not be decoded — \(error.localizedDescription)")
        }
    }

    // MARK: - Testing seam

    /// Exposed so the coalescing and ring behaviour can be exercised without
    /// waiting 90 seconds or touching the real support directory.
    func _setLastWriteForTesting(_ date: Date?) { lastWrite = date }
    var _trailingFlushIsArmedForTesting: Bool { trailingTimer?.isValid == true }
    var _pendingForTesting: AutoSaveEntry? { pending }
}
