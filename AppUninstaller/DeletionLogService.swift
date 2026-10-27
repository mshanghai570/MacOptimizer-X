import Foundation
import AppKit

// MARK: - 废纸篓记录模型（用于跟踪删除的文件以便恢复）
struct TrashRecord: Codable, Identifiable {
    let id: UUID
    let originalPath: String      // 原始路径
    let trashPath: String?        // 废纸篓中的路径
    let fileName: String          // 文件名
    let size: Int64               // 文件大小
    let deletionDate: Date        // 删除时间
    let category: String          // 删除来源 (SmartClean, DeepClean, etc.)
    var isRestored: Bool          // 是否已恢复
    
    init(originalPath: String, trashPath: String?, size: Int64, category: String) {
        self.id = UUID()
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.fileName = URL(fileURLWithPath: originalPath).lastPathComponent
        self.size = size
        self.deletionDate = Date()
        self.category = category
        self.isRestored = false
    }
}

// MARK: - 删除日志服务
/// 记录删除的文件，支持恢复到原位置
class DeletionLogService: ObservableObject {
    static let shared = DeletionLogService()
    
    private let fileManager = FileManager.default
    private let logDirectory: URL
    private let dateFormatter: ISO8601DateFormatter
    
    @Published var deletionRecords: [TrashRecord] = []
    
    // 日志保留天数
    private let retentionDays: Int = 30
    
    private init() {
        // 日志存储目录: ~/Library/Application Support/MacOptimizer/deletion_logs/
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDirectory = appSupport.appendingPathComponent("MacOptimizer/deletion_logs")
        
        // 创建目录
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        
        // 加载今天的日志
        loadTodayLog()
        
        // 清理过期日志
        cleanupOldLogs()
    }
    
    // MARK: - 公共 API
    
    /// 安全删除文件并记录日志。
    /// - Parameters:
    ///   - url: 要删除的文件 URL
    ///   - category: 删除来源类别
    ///   - permanent: true 时直接彻底删除（可再生的缓存/日志类垃圾），false 时移入废纸篓可恢复
    /// - Returns: 删除是否成功
    @discardableResult
    func logAndDelete(at url: URL, category: String = "SmartClean", permanent: Bool = false) -> Bool {
        let normalizedURL = url.standardizedFileURL
        let originalPath = normalizedURL.path

        // Scan results can overlap (for example a cache directory and one of its
        // children) or become stale while a cleanup is running.  Deletion is an
        // idempotent operation: if the requested path is already gone, the
        // requested end state has been reached and must not be reported as a
        // failure or trigger an unnecessary administrator prompt.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: originalPath, isDirectory: &isDirectory) else {
            print("[DeletionLog] ✅ Already removed: \(originalPath)")
            return true
        }

        // 获取文件/目录实际大小（目录必须递归计算，attributesOfItem 只返回条目本身)
        let size: Int64 = isDirectory.boolValue
            ? calculateSize(at: normalizedURL)
            : ((try? fileManager.attributesOfItem(atPath: originalPath))?[.size] as? NSNumber)?.int64Value ?? 0

        func makeRecord(_ trashPath: String?) {
            let record = TrashRecord(
                originalPath: originalPath,
                trashPath: trashPath,
                size: max(size, 0),
                category: category
            )

            DispatchQueue.main.async {
                self.deletionRecords.append(record)
            }
            saveRecord(record)
        }

        // 使用 trashItem 并获取废纸篓中的新路径；permanent 模式跳过废纸篓直接删除
        var trashURL: NSURL?
        do {
            if permanent {
                try fileManager.removeItem(at: normalizedURL)
                guard !fileManager.fileExists(atPath: originalPath) else { return false }
                makeRecord(nil)
                print("[DeletionLog] ✅ Permanently removed: \(originalPath)")
                return true
            }

            try fileManager.trashItem(at: normalizedURL, resultingItemURL: &trashURL)

            // FileManager returning without throwing is normally sufficient, but
            // explicitly verify the source path so every caller gets trustworthy
            // success accounting.
            guard !fileManager.fileExists(atPath: originalPath) else {
                print("[DeletionLog] ❌ Source still exists after trash operation: \(originalPath)")
                return false
            }

            makeRecord(trashURL?.path)
            print("[DeletionLog] ✅ Logged deletion: \(originalPath) -> \(trashURL?.path ?? "unknown")")
            return true
        } catch {
            // Many regenerable cache/log locations cannot be moved to the Trash
            // (sandbox/TCC restrictions treat them as "protected"), yet the item
            // itself is deletable. Without this fallback the cleanup reports
            // failure and the junk is never actually removed. Always attempt a
            // direct removal before giving up.
            do {
                try fileManager.removeItem(at: normalizedURL)
                guard !fileManager.fileExists(atPath: originalPath) else { return false }
                makeRecord(nil)
                print("[DeletionLog] ✅ Trash unavailable, removed directly: \(originalPath)")
                return true
            } catch {
                print("[DeletionLog] ❌ Failed to delete: \(originalPath) - \(error.localizedDescription)")
                return false
            }
        }
    }

    /// 彻底删除（绕过废纸篓）：仅用于可重新生成的缓存、日志和临时文件。
    /// 删除失败时会自动退回移入废纸篓，保证垃圾仍然被移走。
    @discardableResult
    func permanentDelete(at url: URL, category: String) -> Bool {
        let normalizedURL = url.standardizedFileURL
        let originalPath = normalizedURL.path

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: originalPath, isDirectory: &isDirectory) else {
            print("[DeletionLog] ✅ Already removed: \(originalPath)")
            return true
        }

        let size: Int64 = isDirectory.boolValue
            ? calculateSize(at: normalizedURL)
            : ((try? fileManager.attributesOfItem(atPath: originalPath))?[.size] as? NSNumber)?.int64Value ?? 0

        do {
            try fileManager.removeItem(at: normalizedURL)
            guard !fileManager.fileExists(atPath: originalPath) else { return false }

            let record = TrashRecord(
                originalPath: originalPath,
                trashPath: nil,
                size: max(size, 0),
                category: category
            )
            DispatchQueue.main.async {
                self.deletionRecords.append(record)
            }
            saveRecord(record)
            print("[DeletionLog] ✅ Permanently removed: \(originalPath)")
            return true
        } catch {
            // Direct removal denied - fall back to Trash so the item still gets
            // moved out of the way and remains recoverable.
            print("[DeletionLog] ⚠️ Permanent removal failed, falling back to Trash: \(originalPath)")
            return logAndDelete(at: url, category: category, permanent: false)
        }
    }
    
    /// 恢复文件到原位置
    /// - Parameter record: 删除记录
    /// - Returns: 恢复是否成功
    func restore(_ record: TrashRecord) -> Bool {
        guard let trashPath = record.trashPath else {
            print("[DeletionLog] ❌ Cannot restore: no trash path recorded")
            return false
        }
        
        let trashURL = URL(fileURLWithPath: trashPath)
        let originalURL = URL(fileURLWithPath: record.originalPath)
        
        // 检查废纸篓中的文件是否存在
        guard fileManager.fileExists(atPath: trashPath) else {
            print("[DeletionLog] ❌ Cannot restore: file not found in trash")
            return false
        }
        
        // 确保原始目录存在
        let originalDir = originalURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: originalDir, withIntermediateDirectories: true)
        } catch {
            print("[DeletionLog] ❌ Cannot create original directory: \(error)")
            return false
        }
        
        // 如果原位置已存在文件，先备份
        if fileManager.fileExists(atPath: record.originalPath) {
            let backupURL = originalURL.appendingPathExtension("backup_\(Date().timeIntervalSince1970)")
            try? fileManager.moveItem(at: originalURL, to: backupURL)
        }
        
        // 移动文件回原位置
        do {
            try fileManager.moveItem(at: trashURL, to: originalURL)
            
            // 更新记录状态
            if let index = deletionRecords.firstIndex(where: { $0.id == record.id }) {
                DispatchQueue.main.async {
                    self.deletionRecords[index].isRestored = true
                }
            }
            
            print("[DeletionLog] ✅ Restored: \(record.originalPath)")
            return true
            
        } catch {
            print("[DeletionLog] ❌ Failed to restore: \(error.localizedDescription)")
            return false
        }
    }
    
    /// 获取可恢复的文件列表
    func getRestorableRecords() -> [TrashRecord] {
        return deletionRecords.filter { record in
            guard let trashPath = record.trashPath else { return false }
            return !record.isRestored && fileManager.fileExists(atPath: trashPath)
        }
    }
    
    /// 加载所有日志（最近 N 天）
    func loadAllLogs(days: Int = 30) {
        var allRecords: [TrashRecord] = []
        
        let calendar = Calendar.current
        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let dateString = dateFormatter.string(from: date)
            let logFile = logDirectory.appendingPathComponent("deletions_\(dateString).json")
            
            if let data = try? Data(contentsOf: logFile),
               let records = try? JSONDecoder().decode([TrashRecord].self, from: data) {
                allRecords.append(contentsOf: records)
            }
        }
        
        DispatchQueue.main.async {
            self.deletionRecords = allRecords.sorted { $0.deletionDate > $1.deletionDate }
        }
    }
    
    // MARK: - 私有方法
    
    private func loadTodayLog() {
        let dateString = dateFormatter.string(from: Date())
        let logFile = logDirectory.appendingPathComponent("deletions_\(dateString).json")
        
        if let data = try? Data(contentsOf: logFile),
           let records = try? JSONDecoder().decode([TrashRecord].self, from: data) {
            DispatchQueue.main.async {
                self.deletionRecords = records
            }
        }
    }
    
    private func saveRecord(_ record: TrashRecord) {
        let dateString = dateFormatter.string(from: Date())
        let logFile = logDirectory.appendingPathComponent("deletions_\(dateString).json")
        
        // 读取现有记录
        var records: [TrashRecord] = []
        if let data = try? Data(contentsOf: logFile),
           let existingRecords = try? JSONDecoder().decode([TrashRecord].self, from: data) {
            records = existingRecords
        }
        
        // 添加新记录
        records.append(record)
        
        // 保存
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: logFile)
        }
    }
    
    private func cleanupOldLogs() {
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        
        if let files = try? fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey]) {
            for file in files {
                if let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = attrs.creationDate,
                   creationDate < cutoffDate {
                    try? fileManager.removeItem(at: file)
                    print("[DeletionLog] 🗑️ Cleaned up old log: \(file.lastPathComponent)")
                }
            }
        }
    }
    
    private func calculateSize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }
}

// MARK: - 便捷扩展
extension FileManager {
    /// 安全删除文件并记录日志（使用 DeletionLogService）
    func safeTrashItem(at url: URL, category: String = "General") -> Bool {
        return DeletionLogService.shared.logAndDelete(at: url, category: category)
    }
}
