import Foundation

/// Separate storage preserves compatibility with the existing plan and completion history.
final class ActivityTimerStore {
    let storageURL: URL
    private(set) var blockedSaveReason: String?

    init(storageURL: URL) { self.storageURL = storageURL }

    func load() -> ActivityTimerDocument {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return ActivityTimerDocument() }
        do {
            let document = try JSONDecoder().decode(ActivityTimerDocument.self, from: Data(contentsOf: storageURL))
            try document.validate()
            return document
        } catch {
            let backup = storageURL.deletingLastPathComponent()
                .appendingPathComponent("timers.corrupt-\(UUID().uuidString).json")
            let protection: String
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                protection = "原文件已备份为 \(backup.lastPathComponent)。"
            } catch {
                protection = "原文件无法备份，仍保留在原位置。"
            }
            blockedSaveReason = "事项计时数据无法读取，已停止保存以保护记录。\n\(protection)\n请修复或从备份恢复 \(storageURL.path) 后重启应用。\n原因：\(error.localizedDescription)"
            return ActivityTimerDocument()
        }
    }

    func save(_ document: ActivityTimerDocument) throws {
        if let reason = blockedSaveReason { throw ActivityTimerError.invalid(reason) }
        try document.validate()
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: storageURL, options: .atomic)
    }
}
