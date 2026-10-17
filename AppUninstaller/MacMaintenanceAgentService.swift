import CryptoKit
import Foundation

enum MacAgentTool: String, Codable, CaseIterable {
    case scanJunk = "scan_junk"
    case scanLargeFiles = "scan_large_files"
    case scanDuplicates = "scan_duplicates"
    case inspectStorage = "inspect_storage"
    case inspectSystem = "inspect_system"
    case inspectStartup = "inspect_startup"
    case listResults = "list_results"
    case prepareCleanup = "prepare_cleanup"
    case finish
}

struct MacAgentArguments: Codable {
    var minimumSizeMB: Int?
    var olderThanDays: Int?
}

struct MacAgentDecision: Decodable {
    let tool: MacAgentTool
    let arguments: MacAgentArguments?
    let message: String?
}

enum MacAgentFindingCategory: String, Sendable {
    case userCache
    case userLog
    case crashReport
    case savedState
    case systemCache
    case systemLog
    case largeFile
    case duplicateFile
    case startupItem
    case xcodeJunk
    case devCache
}

struct MacAgentFinding: Identifiable, Sendable {
    let id: UUID
    let path: String
    let category: MacAgentFindingCategory
    let size: Int64
    let modifiedAt: Date?

    init(path: String, category: MacAgentFindingCategory, size: Int64, modifiedAt: Date?) {
        self.id = UUID()
        self.path = path
        self.category = category
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

struct MacAgentToolReport: Sendable {
    let tool: MacAgentTool
    let findings: [MacAgentFinding]
    let facts: [String: String]

    var count: Int { findings.count }
    var bytes: Int64 { findings.reduce(0) { $0 + $1.size } }

    var modelSummary: String {
        let categories = Dictionary(grouping: findings, by: \.category)
            .map { key, values in
                "\(key.rawValue)=\(values.count) files/\(values.reduce(0) { $0 + $1.size }) bytes"
            }
            .sorted()
            .joined(separator: ", ")
        let factSummary = facts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        return "tool=\(tool.rawValue); total_files=\(count); total_bytes=\(bytes); categories=[\(categories)]; facts=[\(factSummary)]"
    }
}

struct MacAgentCleanupResult: Sendable {
    let cleanedCount: Int
    let cleanedBytes: Int64
    let failedCount: Int
}

@MainActor
final class MacMaintenanceAgentService: ObservableObject {
    static let shared = MacMaintenanceAgentService()

    @Published private(set) var lastReport: MacAgentToolReport?
    @Published private(set) var pendingCleanup: [MacAgentFinding] = []

    private init() {}

    func execute(_ tool: MacAgentTool, arguments: MacAgentArguments?) async -> MacAgentToolReport {
        let report: MacAgentToolReport
        switch tool {
        case .scanJunk:
            let days = max(1, arguments?.olderThanDays ?? 3)
            report = await Task.detached(priority: .userInitiated) { Self.scanJunk(olderThanDays: days) }.value
        case .scanLargeFiles:
            let minimumMB = max(10, arguments?.minimumSizeMB ?? 100)
            report = await Task.detached(priority: .userInitiated) { Self.scanLargeFiles(minimumSizeMB: minimumMB) }.value
        case .scanDuplicates:
            report = await Task.detached(priority: .userInitiated) { Self.scanDuplicates() }.value
        case .inspectStorage:
            report = await Task.detached(priority: .userInitiated) { Self.inspectStorage() }.value
        case .inspectSystem:
            report = await Task.detached(priority: .userInitiated) { Self.inspectSystem() }.value
        case .inspectStartup:
            report = await Task.detached(priority: .userInitiated) { Self.inspectStartup() }.value
        case .listResults:
            report = lastReport ?? .init(tool: .listResults, findings: [], facts: ["state": "no_previous_scan"])
        case .prepareCleanup:
            let source: MacAgentToolReport
            // Only junk-scan findings are valid input for automatic cleanup.
            // Reusing a previous storage/system/large-file report made a later
            // "clean junk" request prepare zero items and look like the agent
            // had ignored the command.
            if let lastReport, lastReport.tool == .scanJunk {
                source = lastReport
            } else {
                source = await Task.detached(priority: .userInitiated) { Self.scanJunk(olderThanDays: 3) }.value
            }
            let safe = source.findings.filter(Self.isSafeCleanupFinding)
            pendingCleanup = safe
            report = .init(
                tool: .prepareCleanup,
                findings: safe,
                facts: ["confirmation_required": "true", "source_tool": source.tool.rawValue]
            )
        case .finish:
            report = lastReport ?? .init(tool: .finish, findings: [], facts: [:])
        }

        if tool != .finish && tool != .listResults && tool != .prepareCleanup {
            lastReport = report
        }
        return report
    }

    func confirmCleanup() async -> MacAgentCleanupResult {
        let targets = pendingCleanup
        pendingCleanup = []
        guard !targets.isEmpty else { return .init(cleanedCount: 0, cleanedBytes: 0, failedCount: 0) }

        return await Task.detached(priority: .userInitiated) {
            var cleanedCount = 0
            var cleanedBytes: Int64 = 0
            var failedCount = 0
            let manager = FileManager.default
            for finding in targets where Self.isSafeCleanupFinding(finding) {
                do {
                    var resultingURL: NSURL?
                    try manager.trashItem(at: URL(fileURLWithPath: finding.path), resultingItemURL: &resultingURL)
                    cleanedCount += 1
                    cleanedBytes += finding.size
                } catch {
                    failedCount += 1
                }
            }
            return .init(cleanedCount: cleanedCount, cleanedBytes: cleanedBytes, failedCount: failedCount)
        }.value
    }

    func cancelCleanup() {
        pendingCleanup = []
    }

    nonisolated private static func scanJunk(olderThanDays: Int) -> MacAgentToolReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [(URL, MacAgentFindingCategory)] = [
            (home.appendingPathComponent("Library/Caches", isDirectory: true), .userCache),
            (home.appendingPathComponent("Library/Logs", isDirectory: true), .userLog),
            (home.appendingPathComponent("Library/Application Support/CrashReporter", isDirectory: true), .crashReport),
            (home.appendingPathComponent("Library/Saved Application State", isDirectory: true), .savedState),
            (URL(fileURLWithPath: "/Library/Caches", isDirectory: true), .systemCache),
            (URL(fileURLWithPath: "/Library/Logs", isDirectory: true), .systemLog)
        ]
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)
        var findings: [MacAgentFinding] = []
        for (root, category) in roots {
            findings.append(contentsOf: enumerateFiles(at: root, category: category, limit: 20_000) { values in
                guard let modified = values.contentModificationDate else { return true }
                return modified < cutoff
            })
            if findings.count >= 20_000 { break }
        }
        findings.append(contentsOf: scanDeveloperJunk(in: home))
        return .init(tool: .scanJunk, findings: Array(findings.prefix(20_000)), facts: ["older_than_days": String(olderThanDays)])
    }

    /// Xcode and package-manager junk reported at directory granularity.
    /// DerivedData, DeviceSupport and simulator caches are fully regenerated
    /// by the toolchain, so they are safe to remove regardless of age; the
    /// whole caches of npm/Gradle/Maven/Go are equally disposable.
    nonisolated private static func scanDeveloperJunk(in home: URL) -> [MacAgentFinding] {
        let topLevelRoots: [(URL, MacAgentFindingCategory)] = [
            (home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true), .xcodeJunk),
            (home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true), .xcodeJunk),
            (home.appendingPathComponent("Library/Developer/Xcode/watchOS DeviceSupport", isDirectory: true), .xcodeJunk),
            (home.appendingPathComponent("Library/Developer/Xcode/tvOS DeviceSupport", isDirectory: true), .xcodeJunk),
            (home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true), .xcodeJunk)
        ]
        let wholeRoots: [(URL, MacAgentFindingCategory)] = [
            (home.appendingPathComponent(".npm/_cacache", isDirectory: true), .devCache),
            (home.appendingPathComponent(".gradle/caches", isDirectory: true), .devCache),
            (home.appendingPathComponent(".m2/repository", isDirectory: true), .devCache),
            (home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true), .devCache)
        ]

        var findings: [MacAgentFinding] = []
        for (root, category) in topLevelRoots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: []) else { continue }
            for child in children {
                let size = directorySize(of: child)
                guard size >= 1_048_576 else { continue }
                findings.append(.init(path: child.standardizedFileURL.path, category: category, size: size, modifiedAt: nil))
            }
        }
        for (root, category) in wholeRoots {
            let size = directorySize(of: root)
            guard size > 0 else { continue }
            findings.append(.init(path: root.standardizedFileURL.path, category: category, size: size, modifiedAt: nil))
        }
        return findings
    }

    /// Recursive on-disk size of a file or directory tree (errors are ignored).
    nonisolated private static func directorySize(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        guard isDirectory.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    nonisolated private static func scanLargeFiles(minimumSizeMB: Int) -> MacAgentToolReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        let threshold = Int64(minimumSizeMB) * 1_048_576
        var findings: [MacAgentFinding] = []
        for root in roots {
            findings.append(contentsOf: enumerateFiles(at: root, category: .largeFile, limit: 10_000) { values in
                Int64(values.fileSize ?? 0) >= threshold
            })
        }
        findings.sort { $0.size > $1.size }
        return .init(tool: .scanLargeFiles, findings: Array(findings.prefix(10_000)), facts: ["minimum_size_mb": String(minimumSizeMB)])
    }

    nonisolated private static func scanDuplicates() -> MacAgentToolReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        return duplicateReport(in: roots)
    }

    nonisolated static func duplicateReport(in roots: [URL], limit: Int = 50_000) -> MacAgentToolReport {
        var candidates: [MacAgentFinding] = []
        for root in roots {
            candidates.append(contentsOf: enumerateFiles(at: root, category: .duplicateFile, limit: limit) { values in
                (values.fileSize ?? 0) >= 1_024
            })
            if candidates.count >= limit { break }
        }

        let sameSizeGroups = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
        var redundantFiles: [MacAgentFinding] = []
        var duplicateGroupCount = 0

        for sizeGroup in sameSizeGroups {
            var byDigest: [String: [MacAgentFinding]] = [:]
            for finding in sizeGroup {
                guard let digest = sha256(of: URL(fileURLWithPath: finding.path)) else { continue }
                byDigest[digest, default: []].append(finding)
            }
            for digestGroup in byDigest.values where digestGroup.count > 1 {
                duplicateGroupCount += 1
                let sorted = digestGroup.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                redundantFiles.append(contentsOf: sorted.dropFirst())
            }
        }

        redundantFiles.sort { $0.size > $1.size }
        return .init(
            tool: .scanDuplicates,
            findings: redundantFiles,
            facts: [
                "duplicate_groups": String(duplicateGroupCount),
                "hash_algorithm": "SHA-256",
                "files_examined": String(candidates.count)
            ]
        )
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    nonisolated private static func inspectStorage() -> MacAgentToolReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return .init(tool: .inspectStorage, findings: [], facts: [
            "total_bytes": String(values?.volumeTotalCapacity ?? 0),
            "available_bytes": String(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        ])
    }

    nonisolated private static func inspectSystem() -> MacAgentToolReport {
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return .init(tool: .inspectSystem, findings: [], facts: [
            "processor_count": String(process.processorCount),
            "active_processor_count": String(process.activeProcessorCount),
            "physical_memory_bytes": String(process.physicalMemory),
            "uptime_seconds": String(Int(process.systemUptime)),
            "thermal_state": thermal,
            "low_power_mode": process.isLowPowerModeEnabled ? "true" : "false"
        ])
    }

    nonisolated private static func inspectStartup() -> MacAgentToolReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ]
        let findings = roots.flatMap { enumerateFiles(at: $0, category: .startupItem, limit: 2_000) { _ in true } }
        return .init(tool: .inspectStartup, findings: findings, facts: [:])
    }

    nonisolated private static func enumerateFiles(
        at root: URL,
        category: MacAgentFindingCategory,
        limit: Int,
        include: (URLResourceValues) -> Bool
    ) -> [MacAgentFinding] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [MacAgentFinding] = []
        for case let url as URL in enumerator {
            if results.count >= limit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  include(values) else { continue }
            results.append(.init(
                path: url.standardizedFileURL.path,
                category: category,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
        }
        return results
    }

    nonisolated private static func isSafeCleanupFinding(_ finding: MacAgentFinding) -> Bool {
        guard finding.category != .largeFile,
              finding.category != .duplicateFile,
              finding.category != .startupItem else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let allowedRoots = [
            "\(home)/Library/Caches/",
            "\(home)/Library/Logs/",
            "\(home)/Library/Application Support/CrashReporter/",
            "\(home)/Library/Saved Application State/",
            "/Library/Caches/",
            "/Library/Logs/",
            // Xcode junk is fully regenerated by the toolchain.
            "\(home)/Library/Developer/Xcode/DerivedData/",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport/",
            "\(home)/Library/Developer/Xcode/watchOS DeviceSupport/",
            "\(home)/Library/Developer/Xcode/tvOS DeviceSupport/",
            "\(home)/Library/Developer/CoreSimulator/Caches/",
            // Package-manager dependency caches.
            "\(home)/.npm/_cacache",
            "\(home)/.gradle/caches",
            "\(home)/.m2/repository",
            "\(home)/go/pkg/mod/cache"
        ]
        let normalized = URL(fileURLWithPath: finding.path).standardizedFileURL.path
        return allowedRoots.contains(where: normalized.hasPrefix)
    }
}
