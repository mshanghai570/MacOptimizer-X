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
    ///   - permanent: true 时跳过废纸篓直接删除（可再生的缓存/日志类垃圾），
    ///     false 时移入废纸篓（配合 purgeTrashItems 回收空间）
    /// - Returns: 删除是否成功
    @discardableResult
    func logAndDelete(at url: URL, category: String = "SmartClean", permanent: Bool = false) -> Bool {
        if permanent {
            return permanentDelete(at: url, category: category) != nil
        }
        guard fileManager.fileExists(atPath: url.standardizedFileURL.path) else {
            print("[DeletionLog] ✅ Already removed: \(url.standardizedFileURL.path)")
            return true
        }
        return trashAndRecord(at: url, category: category) != nil
    }

    /// Moves the item at `url` to the Trash and returns its log entry.
    ///
    /// Cleaners collect these entries and pass them to `purgeTrashItems`
    /// afterwards: moving a file to the Trash does not free any disk space, so
    /// without that step the "cleaned" figure on screen never matched the free
    /// space the user actually got back.
    @discardableResult
    func trashAndRecord(at url: URL, category: String = "SmartClean") -> TrashRecord? {
        let normalizedURL = url.standardizedFileURL
        let originalPath = normalizedURL.path

        // The path may have disappeared since it was scanned (another cleaner,
        // the app quitting, a sibling cleanup of the same tree). The requested
        // end state is already reached, so report success with nothing to purge.
        guard fileManager.fileExists(atPath: originalPath) else {
            print("[DeletionLog] ✅ Already removed: \(originalPath)")
            return TrashRecord(originalPath: originalPath, trashPath: nil, size: 0, category: category)
        }

        // 获取文件大小：目录必须递归统计，attributes[.size] 只返回目录自身
        // 的 inode 大小（通常几十字节），会让日志和统计严重偏小。
        var isDirectory: ObjCBool = false
        let size: Int64
        if fileManager.fileExists(atPath: originalPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            size = calculateSize(at: normalizedURL)
        } else if let attrs = try? fileManager.attributesOfItem(atPath: originalPath),
                  let fileSize = attrs[.size] as? Int64 {
            size = fileSize
        } else {
            size = calculateSize(at: normalizedURL)
        }

        // 使用 trashItem 并获取废纸篓中的新路径
        var trashURL: NSURL?
        do {
            try fileManager.trashItem(at: normalizedURL, resultingItemURL: &trashURL)
            guard !fileManager.fileExists(atPath: originalPath) else { return nil }

            let record = TrashRecord(
                originalPath: originalPath,
                trashPath: trashURL?.path,
                size: max(size, 0),
                category: category
            )
            DispatchQueue.main.async {
                self.deletionRecords.append(record)
            }
            saveRecord(record)
            return record
        } catch {
            // Many regenerable cache/log locations cannot be moved to the Trash
            // (sandbox/TCC restrictions treat them as "protected"), yet the
            // item itself is deletable. Without this fallback the cleanup
            // reports failure and the junk is never actually removed. Always
            // attempt a direct removal before giving up.
            do {
                try fileManager.removeItem(at: normalizedURL)
                guard !fileManager.fileExists(atPath: originalPath) else { return nil }
                let record = TrashRecord(originalPath: originalPath, trashPath: nil, size: max(size, 0), category: category)
                DispatchQueue.main.async { self.deletionRecords.append(record) }
                saveRecord(record)
                print("[DeletionLog] ✅ Trash unavailable, removed directly: \(originalPath)")
                return record
            } catch {
                print("[DeletionLog] ❌ Failed to delete: \(originalPath) - \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// 彻底删除（绕过废纸篓）：仅用于可重新生成的缓存、日志和临时文件。
    /// 删除失败时会自动退回移入废纸篓，保证垃圾仍然被移走。
    @discardableResult
    func permanentDelete(at url: URL, category: String) -> TrashRecord? {
        let normalizedURL = url.standardizedFileURL
        let originalPath = normalizedURL.path

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: originalPath, isDirectory: &isDirectory) else {
            print("[DeletionLog] ✅ Already removed: \(originalPath)")
            return TrashRecord(originalPath: originalPath, trashPath: nil, size: 0, category: category)
        }

        let size: Int64 = isDirectory.boolValue
            ? calculateSize(at: normalizedURL)
            : ((try? fileManager.attributesOfItem(atPath: originalPath))?[.size] as? NSNumber)?.int64Value ?? 0

        do {
            try fileManager.removeItem(at: normalizedURL)
            guard !fileManager.fileExists(atPath: originalPath) else { return nil }

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
            return record
        } catch {
            // Direct removal denied - fall back to Trash so the item still gets
            // moved out of the way and remains recoverable.
            print("[DeletionLog] ⚠️ Permanent removal failed, falling back to Trash: \(originalPath)")
            return trashAndRecord(at: url, category: category)
        }
    }


    /// Permanently removes Trash entries that a cleanup run just created, so the
    /// bytes reported as cleaned are really reclaimed. Only the supplied records
    /// are touched — anything the user had put in the Trash before the run is
    /// left alone. Log entries are kept as an audit trail; their dangling
    /// trashPath makes them un-restorable, which matches the file being gone.
    @discardableResult
    func purgeTrashItems(_ records: [TrashRecord]) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for record in records {
            guard let trashPath = record.trashPath else { continue }
            let url = URL(fileURLWithPath: trashPath)
            guard fileManager.fileExists(atPath: trashPath) else { continue }
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: trashPath, isDirectory: &isDirectory)
            let size = isDirectory.boolValue ? calculateSize(at: url) : record.size
            do {
                try fileManager.removeItem(at: url)
                count += 1
                bytes += size
            } catch {
                print("[DeletionLog] ⚠️ Failed to purge trashed item: \(trashPath) - \(error.localizedDescription)")
            }
        }
        return (count, bytes)
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
