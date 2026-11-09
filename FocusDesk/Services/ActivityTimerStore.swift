import Foundation
import Darwin

enum ActivityTimerStorageError: LocalizedError {
    case lockBusy
    var errorDescription: String? { L("计时记录正被其他窗口使用，请稍后重试。") }
}

/// Separate storage preserves compatibility with the existing plan and completion history.
final class ActivityTimerStore {
    let storageURL: URL
    private(set) var blockedSaveReason: String?
    private var cachedDocument: ActivityTimerDocument?
    private var cachedSignature: FileSignature?
    private var needsMigrationBackup = false
    private let lockTimeout: TimeInterval

    init(storageURL: URL, lockTimeout: TimeInterval = 2) {
        self.storageURL = storageURL
        self.lockTimeout = lockTimeout
    }

    func load() -> ActivityTimerDocument {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return ActivityTimerDocument() }
        do {
            return try update { _ in }
        } catch {
            if error is ActivityTimerStorageError {
                // A temporary lock is not evidence of corruption. Atomic snapshots
                // remain readable; merge sleep boundaries in memory until retry.
                if var document = try? readDocument(), let boundaries = try? sleepBoundaries() {
                    for (_, boundary) in boundaries.sorted(by: { $0.1.date < $1.1.date }) { boundary.apply(to: &document) }
                    return document
                }
            }
            let backup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("timers.corrupt-\(UUID().uuidString).json")
            let protection: String
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                protection = L("原文件已备份为 %@。", "\(backup.lastPathComponent)")
            } catch {
                protection = L("原文件无法备份，仍保留在原位置。")
            }
            blockedSaveReason = L("事项计时数据无法读取，已停止保存以保护记录。\n%@\n请修复或从备份恢复 %@ 后重启应用。\n原因：%@", "\(protection)", "\(storageURL.path)", "\(error.localizedDescription)")
            return ActivityTimerDocument()
        }
    }

    func save(_ document: ActivityTimerDocument) throws {
        if let reason = blockedSaveReason { throw ActivityTimerError.invalid(reason) }
        try withFileLock {
            _ = try readDocument()
            try writeDocument(document)
        }
    }

    /// Read, change and atomically replace under one interprocess lock. A stale
    /// window can no longer overwrite activities or sessions created elsewhere.
    func update(mergingSleepBeforeChange: Bool = true, handledSleepBoundaryIDs: Set<UUID> = [],
                _ change: (inout ActivityTimerDocument) throws -> Void) throws -> ActivityTimerDocument {
        if let reason = blockedSaveReason { throw ActivityTimerError.invalid(reason) }
        return try withFileLock {
            let previous = try readDocument()
            var candidate = previous
            candidate.version = 2
            let sleepFiles = try sleepBoundaries()
            if mergingSleepBeforeChange {
                for (_, boundary) in sleepFiles.sorted(by: { $0.1.date < $1.1.date }) { boundary.apply(to: &candidate) }
            }
            try change(&candidate)
            // A Start request can have been queued just before sleep and committed afterward.
            for (_, boundary) in sleepFiles.sorted(by: { $0.1.date < $1.1.date }) where !handledSleepBoundaryIDs.contains(boundary.id) {
                boundary.apply(to: &candidate)
            }
            if candidate != previous { try writeDocument(candidate) }
            for (url, _) in sleepFiles { try? FileManager.default.removeItem(at: url) }
            return candidate
        }
    }

    /// Only the small boundary journal is written synchronously before system sleep.
    /// Full-document merging is performed by the serial worker, including after restart.
    func recordSleepBoundary(_ boundary: ActivitySleepBoundary) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("timers.sleep-\(boundary.id.uuidString).json")
        try JSONEncoder().encode(boundary).write(to: url, options: .atomic)
    }

    private func sleepBoundaries() throws -> [(URL, ActivitySleepBoundary)] {
        let urls = try FileManager.default.contentsOfDirectory(at: storageURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("timers.sleep-") && $0.pathExtension == "json" }
        return try urls.compactMap { url in
            do { return (url, try JSONDecoder().decode(ActivitySleepBoundary.self, from: Data(contentsOf: url))) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return nil
            }
        }
    }

    private func readDocument() throws -> ActivityTimerDocument {
        guard let signature = try fileSignature() else {
            cachedDocument = nil
            cachedSignature = nil
            needsMigrationBackup = false
            return ActivityTimerDocument()
        }
        if signature == cachedSignature, let cachedDocument { return cachedDocument }
        var document = try JSONDecoder().decode(ActivityTimerDocument.self, from: Data(contentsOf: storageURL))
        try document.validate()
        needsMigrationBackup = document.version == 1
        document.assignActivityColors()
        // Atomic replacements change the inode; in-place external writes change mtime/ctime.
        // Recheck after decoding so a concurrent external change never gets a trusted cache entry.
        if try fileSignature() == signature {
            cachedSignature = signature
            cachedDocument = document
        } else {
            cachedSignature = nil
            cachedDocument = nil
        }
        return document
    }

    private func writeDocument(_ document: ActivityTimerDocument) throws {
        var document = document
        document.version = 2
        try document.validate()
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if needsMigrationBackup {
            let base = storageURL.deletingPathExtension().lastPathComponent
            var backup = storageURL.deletingLastPathComponent().appendingPathComponent("\(base).v1-backup.json")
            if FileManager.default.fileExists(atPath: backup.path) {
                // Retrying an interrupted migration reuses its exact backup. If
                // a legacy app wrote a newer file, keep both versions intact.
                if try Data(contentsOf: backup) != Data(contentsOf: storageURL) {
                    backup = storageURL.deletingLastPathComponent().appendingPathComponent("\(base).v1-backup-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: storageURL, to: backup)
                }
            } else {
                try FileManager.default.copyItem(at: storageURL, to: backup)
            }
        }
        let encoder = JSONEncoder()
        // Compact JSON reduces encoding and replacement cost as history grows.
        // Sorted keys keep snapshots deterministic without display whitespace.
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: storageURL, options: .atomic)
        needsMigrationBackup = false
        cachedSignature = nil
        cachedDocument = nil
    }

    private struct FileSignature: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        var changedSeconds: Int
        var changedNanoseconds: Int
    }

    private func fileSignature() throws -> FileSignature? {
        var metadata = stat()
        guard storageURL.path.withCString({ stat($0, &metadata) }) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileSignature(device: metadata.st_dev, inode: metadata.st_ino, size: metadata.st_size,
                             modifiedSeconds: metadata.st_mtimespec.tv_sec, modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
                             changedSeconds: metadata.st_ctimespec.tv_sec, changedNanoseconds: metadata.st_ctimespec.tv_nsec)
    }

    private func withFileLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(storageURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ActivityTimerStorageError.lockBusy
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}

struct ActivityTimerIOResult {
    var document: ActivityTimerDocument
    var completionID: UUID?
    var error: String?
    var undo: ActivityTimerUndo?
    // Constructed on the worker and transferred once. The worker never keeps
    // or accesses this mutable cache after handing it to the main actor.
    var preparedStatistics: ActivityStatisticsCache?
}

actor ActivityTimerIO {
    private let storage: ActivityTimerStore
    private var preparedSessions: [ActivityTimerSession]?
    private var preparedDay: Date?
    private var preparedCalendar: Calendar?

    init(storageURL: URL) { storage = ActivityTimerStore(storageURL: storageURL, lockTimeout: 0.8) }

    func load(at date: Date) -> ActivityTimerIOResult {
        let document = storage.load()
        if let error = storage.blockedSaveReason { return .init(document: document, error: error) }
        do {
            var result = try refresh(at: date, sleepBoundary: nil)
            // Loading an expired timer restores its quiet reminder without
            // replaying a completion effect from the previous app session.
            result.completionID = nil
            return result
        }
        catch { return .init(document: document, error: error.localizedDescription) }
    }

    func refresh(at date: Date, sleepBoundary: ActivitySleepBoundary?) throws -> ActivityTimerIOResult {
        try Task.checkCancellation()
        var completed = false
        let document = try storage.update {
            try Task.checkCancellation()
            sleepBoundary?.apply(to: &$0)
            completed = $0.completeCountdown(at: date)
        }
        return try result(document: document, at: date, completionID: completed ? document.pendingCountdownSessionID : nil)
    }

    func apply(_ action: ActivityTimerAction, at date: Date, expectedSessionID: UUID?,
               expectedPauseState: Bool?, sleepBoundary: ActivitySleepBoundary?) throws -> ActivityTimerIOResult {
        var previousCompletion: UUID?
        var undo: ActivityTimerUndo?
        let handled = Set(sleepBoundary.map { [$0.id] } ?? [])
        let document = try storage.update(mergingSleepBeforeChange: false, handledSleepBoundaryIDs: handled) {
            previousCompletion = $0.pendingCountdownSessionID
            sleepBoundary?.apply(to: &$0)
            let before = $0
            try action.apply(to: &$0, at: date, expectedSessionID: expectedSessionID, expectedPauseState: expectedPauseState)
            undo = action.undoToken(from: before, to: $0)
        }
        // User writes are acknowledged even if the originating view goes away.
        return try result(document: document, at: date,
                          completionID: previousCompletion != document.pendingCountdownSessionID ? document.pendingCountdownSessionID : nil,
                          undo: undo, cancellable: false)
    }

    private func result(document: ActivityTimerDocument, at date: Date,
                        completionID: UUID?, undo: ActivityTimerUndo? = nil,
                        cancellable: Bool = true) throws -> ActivityTimerIOResult {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        var prepared: ActivityStatisticsCache?
        if preparedSessions != document.sessions || preparedDay != day || preparedCalendar != calendar {
            let cache = ActivityStatisticsCache()
            _ = cache.value(document: document, revision: 0, at: date, calendar: calendar)
            if cancellable { try Task.checkCancellation() }
            prepared = cache
            preparedSessions = document.sessions
            preparedDay = day
            preparedCalendar = calendar
        }
        return .init(document: document, completionID: completionID, undo: undo, preparedStatistics: prepared)
    }
}
