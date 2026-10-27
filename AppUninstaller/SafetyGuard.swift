import Foundation
import AppKit

/// 安全防护服务 - 防止误删系统关键文件和应用配置
class SafetyGuard {
    static let shared = SafetyGuard()
    
    private let fileManager = FileManager.default
    
    // MARK: - 系统关键文件白名单
    
    /// macOS 系统关键 Preferences 文件 (绝对不能删除)
    private let systemPreferencesWhitelist: Set<String> = [
        // 核心系统设置
        "com.apple.finder.plist",
        "com.apple.dock.plist",
        "com.apple.LaunchServices.plist",
        "com.apple.loginwindow.plist",
        "com.apple.menuextra.plist",
        "com.apple.systempreferences.plist",
        ".GlobalPreferences.plist",
        
        // 系统UI和交互
        "com.apple.spaces.plist",
        "com.apple.notificationcenterui.plist",
        "com.apple.notificationcenterui-donotdisturb.plist",
        "com.apple.controlcenter.plist",
        "com.apple.Spotlight.plist",
        "com.apple.SpotlightServer.plist",
        
        // 输入设备
        "com.apple.driver.AppleBluetoothMultitouch.mouse.plist",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad.plist",
        "com.apple.AppleMultitouchTrackpad.plist",
        "com.apple.keyboard.plist",
        
        // 辅助功能
        "com.apple.universalaccess.plist",
        "com.apple.accessibility.plist",
        
        // 系统内置应用
        "com.apple.Safari.plist",
        "com.apple.mail.plist",
        "com.apple.iCal.plist",
        "com.apple.Notes.plist",
        "com.apple.Contacts.plist",
        "com.apple.Maps.plist",
        "com.apple.Photos.plist",
        "com.apple.Music.plist",
        "com.apple.TV.plist",
        "com.apple.Podcasts.plist",
        "com.apple.Books.plist",
        "com.apple.FaceTime.plist",
        "com.apple.iChat.plist",
        "com.apple.TextEdit.plist",
        "com.apple.Preview.plist",
        "com.apple.QuickTimePlayerX.plist",
        
        // 系统服务
        "com.apple.screensaver.plist",
        "com.apple.screencaptureui.plist",
        "com.apple.Siri.plist",
        "com.apple.speech.synthesis.general.prefs.plist",
        "com.apple.TimeMachine.plist",
        "com.apple.security.plist",
        "com.apple.networkextension.plist",
        
        // iCloud 和同步
        "com.apple.iCloud.plist",
        "com.apple.bird.plist",
        "com.apple.cloudd.plist",
        
        // 开发者工具
        "com.apple.dt.Xcode.plist",
        "com.apple.dt.instruments.plist",
        
        // 其他关键系统文件
        "com.apple.HIToolbox.plist",
        "com.apple.LaunchServices.QuarantineEventsV2",
        "com.apple.recentitems.plist",
        "com.apple.sidebarlists.plist",
        
        // 账户与认证 (重要修复)
        "MobileMeAccounts.plist",           // iCloud 账户信息 (旧名 MobileMe)
        "com.apple.accountsd.plist",        // 账户守护进程
        "com.apple.Passbook.plist",         // 钱包/Apple Pay
        "com.apple.commerce.plist",         // App Store 购买记录
        "com.apple.tourist.plist"           // 系统引导状态
    ]
    
    /// 系统关键目录 (绝对不能扫描/删除)
    private let protectedDirectories: Set<String> = [
        // 系统核心目录
        "/System",
        "/Library/Apple",
        "/Library/Security",
        "/usr",
        "/bin",
        "/sbin",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        
        // ⚠️ 严重 BUG 修复：保护用户媒体目录，防止误删视频/音乐/图片等
        "~/Movies",
        "~/Music",
        "~/Pictures",
        "~/Documents",
        "~/Desktop",
        "~/Downloads",
        
        // ⚠️ 严重 BUG 修复：保护应用程序目录，防止破坏应用
        "/Applications",
        "~/Applications",
        
        // 用户关键数据
        "~/Library/Keychains",
        "~/Library/KeyboardServices",
        "~/Library/Cookies",
        "~/Library/Safari/Bookmarks.plist",
        "~/Library/Safari/History.db",
        "~/Library/Mail",
        "~/Library/Messages",
        "~/Library/Photos",
        
        // 密码和认证管理器
        "~/Library/Application Support/1Password",
        "~/Library/Application Support/Bitwarden",
        "~/Library/Application Support/LastPass",
        "~/Library/Application Support/KeePassXC",
        
        // 浏览器关键数据
        "~/Library/Application Support/Google/Chrome/Default/Cookies",
        "~/Library/Application Support/Google/Chrome/Default/Login Data",
        "~/Library/Application Support/Firefox/Profiles",
        "~/Library/Safari/CloudTabs.db",
        
        // 开发环境
        "~/Library/Developer/Xcode/UserData",
        "~/.ssh",
        "~/.gnupg",
        
        // 云存储和同步
        "~/Library/Application Support/iCloud",
        "~/Library/Mobile Documents"
    ]
    
    /// 常见应用关键配置 (需要特别小心)
    private let criticalAppPatterns: [String] = [
        "com.google.Chrome",
        "com.microsoft.VSCode",
        "com.microsoft.edgemac",
        "com.jetbrains.",  // 所有 JetBrains IDE
        "com.tencent.xinWeChat",
        "com.tencent.qq",
        "com.tencent.meeting",
        "org.mozilla.firefox",
        "com.apple.dt.Xcode",
        "com.docker.docker",
        "com.spotify.client",
        "com.adobe.",  // Adobe 系列
        "com.figma.Desktop",
        "com.notion.id",
        "com.slack.Slack",
        "us.zoom.xos",
        "com.skype.skype",
        "org.telegram.desktop",
        "com.facebook.archon.developerID",  // WhatsApp
        "com.readdle.PDFExpert-Mac",
        "com.tapbots.TweetbotMac"
    ]
    
    // MARK: - 应用检测缓存
    
    private var installedAppCache: Set<String>?
    private var cacheTimestamp: Date?
    private let cacheValidityDuration: TimeInterval = 300 // 5分钟
    
    // MARK: - 公共API
    
    /// 检查文件/目录是否可以安全删除
    /// - Parameters:
    ///   - url: 要检查的文件/目录URL
    ///   - ignoreProtection: 是否忽略目录保护（用于用户明确选择的大文件清理）
    /// - Returns: true表示安全,false表示不能删除
    func isSafeToDelete(_ url: URL, ignoreProtection: Bool = false) -> Bool {
        let path = url.path
        
        // 1. 检查是否是受保护的目录
        // 如果 ignoreProtection 为 true (用于大文件清理)，则放宽对 protectedDirectories 的检查
        // 但仍然禁止删除系统核心目录
        if isProtectedPath(path) {
            if ignoreProtection {
                // 定义绝对不可删除的核心系统目录
                let coreSystemPaths = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/private/var/root", "/Library/Apple", "/Library/Security"]
                let isCore = coreSystemPaths.contains { path.hasPrefix($0) }
                
                if isCore {
                    print("[SafetyGuard] 🛡️ Core system path, cannot delete even with bypass: \(path)")
                    return false
                } else {
                    print("[SafetyGuard] ⚠️ Bypassing directory protection for: \(path)")
                    // 允许继续后续检查
                }
            } else {
                print("[SafetyGuard] 🛡️ Protected path, cannot delete: \(path)")
                return false
            }
        }
        
        // 2. 检查是否是系统文件
        if isSystemFile(url) {
            print("[SafetyGuard] 🛡️ System file, cannot delete: \(path)")
            return false
        }
        
        // 3. 检查是否是系统关键Preferences
        if isSystemPreference(url) {
            print("[SafetyGuard] 🛡️ System preference, cannot delete: \(path)")
            return false
        }
        
        // 4. 检查是否是关键应用配置
        if isCriticalAppConfig(url) {
            print("[SafetyGuard] ⚠️ Critical app config, risky to delete: \(path)")
            // 注意: 这里返回true,但调用者应该谨慎处理
        }
        
        // 5. 🛡️ 新增: 保护已安装应用的关键目录
        if let protection = isInstalledAppProtectedPath(url) {
            if !protection.isSafeSubdir {
                print("[SafetyGuard] 🛡️ Installed app data protected: \(path) (app: \(protection.bundleId))")
                return false
            }
            // 如果是安全子目录 (Caches, tmp, Logs)，允许删除
            print("[SafetyGuard] ✅ Safe cache subdir for installed app: \(path)")
        }
        
        return true
    }
    
    /// 检查应用是否已安装 (增强版,多重验证)
    /// - Parameter bundleId: Bundle ID 或应用名称
    /// - Returns: true表示已安装,false表示未安装
    func isApplicationInstalled(_ identifier: String) -> Bool {
        let lowerId = identifier.lowercased()
        
        // 1. 检查运行中的应用
        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier?.lowercased(), bundleId == lowerId {
                return true
            }
            if let name = app.localizedName?.lowercased(), name == lowerId {
                return true
            }
        }
        
        // 2. 检查已安装应用缓存
        let installedApps = getInstalledApplications()
        if installedApps.contains(lowerId) {
            return true
        }
        
        // 3. 模糊匹配 - 检查是否包含在已安装应用中
        for installedId in installedApps {
            if installedId.contains(lowerId) || lowerId.contains(installedId) {
                // 额外检查:避免误匹配过短的字符串
                if min(installedId.count, lowerId.count) >= 5 {
                    return true
                }
            }
        }
        
        // 4. 检查是否是系统保留
        if lowerId.hasPrefix("com.apple.") || lowerId.hasPrefix("apple") {
            return true
        }
        
        return false
    }
    
    /// 检查Preference文件对应的应用是否已安装
    /// - Parameter preferenceURL: Preference文件URL
    /// - Returns: true表示应用已安装,false表示可能是孤立文件
    func isPreferenceOrphaned(_ preferenceURL: URL) -> Bool {
        let filename = preferenceURL.deletingPathExtension().lastPathComponent
        
        // 1. 系统文件永远不是孤立的
        if systemPreferencesWhitelist.contains(preferenceURL.lastPathComponent) {
            return false
        }
        
        // 2. com.apple.* 文件不是孤立的
        if filename.hasPrefix("com.apple.") {
            return false
        }
        
        // 3. 检查文件是否最近被修改 (7天内修改过可能仍在使用)
        if let modDate = try? preferenceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            let daysSinceModification = Date().timeIntervalSince(modDate) / 86400
            if daysSinceModification < 7 {
                print("[SafetyGuard] ℹ️ \(filename) modified recently, keeping")
                return false
            }
        }
        
        // 4. 检查对应应用是否已安装
        return !isApplicationInstalled(filename)
    }
    
    /// 获取安全删除建议
    /// - Parameter url: 要删除的文件URL
    /// - Returns: 删除建议和风险级别
    func getDeletionAdvice(for url: URL) -> (riskLevel: DeletionRiskLevel, advice: String) {
        if !isSafeToDelete(url) {
            return (.critical, "此文件是系统关键文件,删除可能导致系统或应用无法正常工作")
        }
        
        if isSystemPreference(url) {
            return (.critical, "此文件是系统配置,删除将导致系统设置丢失")
        }
        
        if isCriticalAppConfig(url) {
            return (.high, "此文件是重要应用配置,删除将导致应用设置丢失和登录状态清除")
        }
        
        if url.path.contains("/Library/Preferences") {
            if isPreferenceOrphaned(url) {
                return (.low, "此文件可能是已卸载应用的残留配置")
            } else {
                return (.medium, "此文件对应的应用仍在使用,建议保留")
            }
        }
        
        if url.path.contains("/Library/Caches") {
            return (.low, "缓存文件,可以安全删除,应用会自动重建")
        }
        
        if url.path.contains("/Library/Logs") {
            return (.low, "日志文件,可以安全删除")
        }
        
        return (.medium, "建议移至废纸篓而非直接删除")
    }
    
    // MARK: - 私有方法
    
    private func isProtectedPath(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        
        for protectedDir in protectedDirectories {
            let expandedProtected = NSString(string: protectedDir).expandingTildeInPath
            if expandedPath.hasPrefix(expandedProtected) {
                return true
            }
        }
        
        return false
    }
    
    private func isSystemFile(_ url: URL) -> Bool {
        // 检查文件是否在系统目录下
        let path = url.path
        if path.hasPrefix("/System/") || 
           path.hasPrefix("/usr/") || 
           path.hasPrefix("/bin/") || 
           path.hasPrefix("/sbin/") {
            return true
        }
        
        // 检查文件是否有系统保护属性
        if let values = try? url.resourceValues(forKeys: [.isSystemImmutableKey, .isUserImmutableKey]) {
            if values.isSystemImmutable == true || values.isUserImmutable == true {
                return true
            }
        }
        
        return false
    }
    
    private func isSystemPreference(_ url: URL) -> Bool {
        // 必须在Preferences目录下
        guard url.path.contains("/Library/Preferences") else {
            return false
        }
        
        let filename = url.lastPathComponent
        return systemPreferencesWhitelist.contains(filename)
    }
    
    private func isCriticalAppConfig(_ url: URL) -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent
        
        for pattern in criticalAppPatterns {
            if filename.hasPrefix(pattern) || filename.contains(pattern) {
                return true
            }
        }
        
        return false
    }
    
    /// 🛡️ 检查路径是否是已安装应用的受保护目录
    /// - Parameter url: 要检查的路径
    /// - Returns: 如果是已安装应用的目录，返回 (bundleId, 是否是安全子目录)；否则返回 nil
    private func isInstalledAppProtectedPath(_ url: URL) -> (bundleId: String, isSafeSubdir: Bool)? {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        // 安全的子目录名称 - 这些可以安全删除
        let safeSubdirNames: Set<String> = [
            "Cache", "Caches", "cache", "caches",
            "tmp", "Tmp", "temp", "Temp",
            "Logs", "logs", "Log", "log",
            "GPUCache", "ShaderCache", "Code Cache",
            "CachedData", "CachedExtensions",
            // Electron/Chromium 的 Service Worker 缓存（Slack 等）。
            "CacheStorage",
            // 邮件下载附件可从服务器重新下载。
            "Mail Downloads", "attachments"
        ]
        
        // 1. 检查 ~/Library/Containers/<bundle-id>
        let containersPath = home + "/Library/Containers/"
        if path.hasPrefix(containersPath) {
            let relativePath = String(path.dropFirst(containersPath.count))
            let components = relativePath.components(separatedBy: "/")
            guard let bundleId = components.first, !bundleId.isEmpty else { return nil }
            
            // 检查应用是否已安装
            if isApplicationInstalled(bundleId) {
                // 检查是否是安全子目录
                // 例如: ~/Library/Containers/com.xxx/Data/Library/Caches
                let isSafe = components.count > 1 && components.contains { safeSubdirNames.contains($0) }
                return (bundleId, isSafe)
            }
        }
        
        // 2. 检查 ~/Library/Application Support/<app-name>
        let appSupportPath = home + "/Library/Application Support/"
        if path.hasPrefix(appSupportPath) {
            let relativePath = String(path.dropFirst(appSupportPath.count))
            let components = relativePath.components(separatedBy: "/")
            guard let appName = components.first, !appName.isEmpty else { return nil }
            
            // 跳过通用目录（不属于特定应用）
            let genericDirs: Set<String> = [
                "AddressBook", "CallHistoryDB", "CallHistoryTransactions",
                "CloudDocs", "CrashReporter", "FileProvider", "Knowledge",
                "MobileSync", "SyncServices", "Ubiquity"
            ]
            if genericDirs.contains(appName) { return nil }
            
            // 检查应用是否已安装
            if isApplicationInstalled(appName) {
                // 检查是否是安全子目录
                let isSafe = components.count > 1 && components.contains { safeSubdirNames.contains($0) }
                return (appName, isSafe)
            }
        }
        
        // 3. 检查 ~/Library/Caches/<bundle-id> - 这总是安全的
        let cachesPath = home + "/Library/Caches/"
        if path.hasPrefix(cachesPath) {
            let relativePath = String(path.dropFirst(cachesPath.count))
            let components = relativePath.components(separatedBy: "/")
            guard let bundleId = components.first, !bundleId.isEmpty else { return nil }
            
            if isApplicationInstalled(bundleId) {
                // ~/Library/Caches 下的内容总是安全的
                return (bundleId, true)
            }
        }
        
        return nil
    }
    
    /// 获取所有已安装应用的标识符 (带缓存)
    private func getInstalledApplications() -> Set<String> {
        // 检查缓存是否有效
        if let cache = installedAppCache,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidityDuration {
            return cache
        }
        
        // 重新扫描
        var apps = Set<String>()
        
        // 1. 扫描应用目录
        let appDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        
        for dir in appDirs {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            
            for item in contents where item.hasSuffix(".app") {
                let appPath = (dir as NSString).appendingPathComponent(item)
                let plistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
                
                // 添加应用名称
                let appName = (item as NSString).deletingPathExtension.lowercased()
                apps.insert(appName)
                
                // 读取Bundle ID
                if let plist = NSDictionary(contentsOfFile: plistPath),
                   let bundleId = plist["CFBundleIdentifier"] as? String {
                    apps.insert(bundleId.lowercased())
                    
                    // 添加Bundle ID的各个组件
                    for component in bundleId.components(separatedBy: ".") where component.count > 3 {
                        apps.insert(component.lowercased())
                    }
                }
            }
        }
        
        // 2. 添加Homebrew Cask应用
        let homebrewPaths = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        for caskPath in homebrewPaths {
            if let casks = try? fileManager.contentsOfDirectory(atPath: caskPath) {
                for cask in casks {
                    apps.insert(cask.lowercased())
                }
            }
        }
        
        // 3. 添加运行中的应用
        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier {
                apps.insert(bundleId.lowercased())
            }
            if let name = app.localizedName {
                apps.insert(name.lowercased())
            }
        }
        
        // 4. 添加系统安全名单
        let safelist = [
            "finder", "dock", "spotlight", "safari", "mail", "messages", "photos",
            "music", "tv", "podcasts", "books", "notes", "calendar", "contacts",
            "facetime", "preview", "textedit", "quicktime", "appstore",
            "systempreferences", "activitymonitor", "terminal", "console",
            "chrome", "firefox", "edge", "opera", "brave",
            "vscode", "xcode", "jetbrains", "intellij", "pycharm", "webstorm",
            "docker", "postman", "figma", "sketch", "notion", "obsidian",
            "slack", "discord", "zoom", "skype", "telegram", "wechat", "qq",
            "1password", "bitwarden", "lastpass", "dropbox", "onedrive", "googledrive"
        ]
        for safe in safelist {
            apps.insert(safe)
        }
        
        // 更新缓存
        installedAppCache = apps
        cacheTimestamp = Date()
        
        return apps
    }
    
    /// 使缓存失效 (当应用安装/卸载后调用)
    func invalidateCache() {
        installedAppCache = nil
        cacheTimestamp = nil
    }
}

// MARK: - 删除风险级别

enum DeletionRiskLevel: String {
    case low = "低风险"
    case medium = "中等风险"
    case high = "高风险"
    case critical = "严重风险"
    
    var color: String {
        switch self {
        case .low: return "🟢"
        case .medium: return "🟡"
        case .high: return "🟠"
        case .critical: return "🔴"
        }
    }
}
