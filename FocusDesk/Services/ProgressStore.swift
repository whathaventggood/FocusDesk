import Foundation

/// Plan and progress are committed together, avoiding a partially saved pair of JSON files.
struct ProgressDocument: Codable, Equatable {
    var version = 1
    var tasks: [PlanTask]
    var history: [DailyProgress]
}

final class ProgressStore {
    struct LoadResult {
        var document: ProgressDocument
        var notice: String?
    }

    let storageURL: URL
    private(set) var blockedSaveReason: String?

    init(storageURL: URL) {
        self.storageURL = storageURL
    }

    func load(defaultTasks: [PlanTask]) -> LoadResult {
        let fallback = ProgressDocument(tasks: defaultTasks, history: [])
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return LoadResult(document: fallback, notice: nil)
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            let document: ProgressDocument
            // Earlier releases stored only a task array in plan.json.
            if let legacy = try? decoder.decode([PlanTask].self, from: data) {
                document = ProgressDocument(tasks: legacy, history: [])
            } else {
                document = try decoder.decode(ProgressDocument.self, from: data)
            }
            try Self.validate(document)
            return LoadResult(document: document, notice: nil)
        } catch {
            let originalError = error.localizedDescription
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = storageURL.deletingLastPathComponent().appendingPathComponent(
                "plan.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json"
            )
            let protection: String
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                protection = "原文件已备份为 \(backup.lastPathComponent)。"
            } catch {
                protection = "原文件无法备份，请检查文件夹权限。"
            }
            let reason = "本地计划或历史记录无法读取，已暂时展示默认计划。\n\(protection)\n为保护历史记录，已停止保存。请在“设置”中确认备份并恢复默认计划；也可以手动修复 \(storageURL.path) 后重启应用。\n原因：\(originalError)"
            blockedSaveReason = reason
            return LoadResult(document: fallback, notice: reason)
        }
    }

    func save(_ document: ProgressDocument) throws {
        if let reason = blockedSaveReason {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        try write(document)
    }

    /// Called only after an explicit destructive-recovery confirmation in the UI.
    func recover(with document: ProgressDocument) throws {
        guard blockedSaveReason != nil else { return try save(document) }
        let backup = storageURL.deletingLastPathComponent().appendingPathComponent(
            "plan.corrupt-recovery-\(UUID().uuidString).json"
        )
        // A new exact backup is required before replacing the unreadable original.
        do {
            try FileManager.default.copyItem(at: storageURL, to: backup)
        } catch {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey:
                "无法备份原文件，已取消恢复，原数据未被覆盖。\n\(error.localizedDescription)"])
        }
        try write(document)
        blockedSaveReason = nil
    }

    private func write(_ document: ProgressDocument) throws {
        try Self.validate(document)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: storageURL, options: .atomic)
    }

    private static func validate(_ document: ProgressDocument) throws {
        guard document.version == 1 else { throw corrupt("无法识别数据文件版本，请使用兼容的 FocusDesk 版本打开。") }
        if let reason = PlanValidator.validate(document.tasks) { throw corrupt(reason) }
        var days = Set<String>()
        for day in document.history {
            guard validDayKey(day.day), days.insert(day.day).inserted,
                  TimeZone(identifier: day.timeZoneIdentifier) != nil else {
                throw corrupt("历史记录日期、时区无效或日期重复。")
            }
            if let reason = PlanValidator.validate(day.tasks.map(\.task)) { throw corrupt(reason) }
            guard day.tasks.allSatisfy({ $0.completedAt?.timeIntervalSinceReferenceDate.isFinite ?? true }) else {
                throw corrupt("历史记录包含无效的完成时间。")
            }
        }
    }

    private static func validDayKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
        let components = key.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3, (1...9_999).contains(components[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2])) else { return false }
        return DailyProgress.dayKey(for: date, calendar: calendar) == key
    }

    private static func corrupt(_ reason: String) -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
