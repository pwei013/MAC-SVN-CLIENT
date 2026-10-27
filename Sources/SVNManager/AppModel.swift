import AppKit
import SwiftUI
import SVNCore

struct Activity: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let failed: Bool
}

enum Screen: String { case repository, workingCopy }

struct RepositoryLoginRequest: Identifiable {
    let id = UUID()
    let url: String
    let username: String
    let reason: String
}

struct UnignoreRequest: Identifiable {
    let id = UUID()
    let plan: SVNUnignorePlan
}

struct UserIgnoreSaveResult {
    let settings: SVNIgnoreConfigSettings
    let backup: URL?
    let refreshWarning: String?
}

struct DirectoryIgnoreRequest: Identifiable {
    let id = UUID()
    let directory: URL
}

struct DirectoryIgnoreSaveOutcome {
    let settings: SVNDirectoryIgnoreSettings
    let backupDirectory: URL?
    let refreshWarning: String?
    let changed: Bool
}

struct FileDiffPresentation: Identifiable, Sendable {
    let id = UUID()
    let files: SVNFileComparison
    let lines: SVNLineComparison
    let changeStarts: [Int]
    let localColumns: Int
    let remoteColumns: Int
    let decorations: SVNComparisonDecorations
    let language: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: Screen = .repository
    @Published var repositoryURL = ""
    @Published var loginRequest: RepositoryLoginRequest?
    @Published var executablePath: String {
        didSet { UserDefaults.standard.set(executablePath, forKey: "svnExecutable") }
    }
    @Published var currentURL = ""
    @Published var loadingRepositoryURL: String?
    @Published var entries: [RepositoryEntry] = []
    @Published var repositorySearch = ""
    @Published var searchesSubdirectories = false
    @Published var repositoryDirectoriesOnly = false
    @Published private(set) var repositorySearchResult: RepositorySearchResult?
    @Published private(set) var completedRepositorySearch: String?
    @Published private(set) var isSearchingRepository = false
    @Published private(set) var globalIgnorePatterns: [String]
    @Published private(set) var showIgnoredFiles: Bool
    @Published var unignoreRequest: UnignoreRequest?
    @Published var directoryIgnoreRequest: DirectoryIgnoreRequest?
    @Published private var repositoryHistory: RecentLocationHistory
    @Published private var workingCopyHistory: RecentLocationHistory
    var recentRepositories: [String] { repositoryHistory.items }
    var recentWorkingCopies: [String] { workingCopyHistory.items }
    @Published var workingDirectory: URL?
    @Published var workingInfo: WorkingCopyInfo?
    @Published var changes: [WorkingCopyChange] = [] { didSet { scheduleChangeFiltering() } }
    @Published var checkedPaths = Set<String>() { didSet { scheduleProjectStateSave() } }
    @Published var changeSelection: String? { didSet { scheduleProjectStateSave() } }
    @Published var changeSearch = "" { didSet { scheduleProjectStateSave(); scheduleChangeFiltering(debounce: true) } }
    @Published var changeStatusFilter = WorkingCopyStatusFilter.all { didSet { scheduleProjectStateSave(); scheduleChangeFiltering() } }
    @Published var changeKindFilter = WorkingCopyKindFilter.all { didSet { scheduleProjectStateSave(); scheduleChangeFiltering() } }
    @Published var changeFilterResult = WorkingCopyFilterResult.empty
    @Published var isFilteringChanges = false
    var changeFilterTask: Task<Void, Never>?
    var changeFilterID = UUID()
    @Published var commitMessage = "" { didSet { scheduleProjectStateSave() } }
    @Published var projectStateWarning: String?
    @Published var busy = false
    @Published var operation = "就绪"
    @Published var alert: String?
    @Published var activities: [Activity] = []
    @Published var diffText = ""
    @Published var diffTitle = ""
    @Published var diffContext = ""
    @Published var fileDiff: FileDiffPresentation?
    @Published var showDiff = false
    @Published var showSettings = false
    @Published var showCommit = false
    @Published var showActivity = false
    @Published var checkoutProgress: CheckoutProgressModel?
    @Published var operationProgress: OperationProgressModel?
    @Published var historySession: HistorySession?
    @Published var incomingSession: IncomingSession?
    @Published var diffReloading = false
    @Published var diffError: String?
    @Published var diffRevisionChoice = "base"
    var diffFileTarget: SVNRemoteDiffTarget?
    var diffReadTask: Task<Void, Never>?
    var diffReadID = UUID()
    let projectStateStore: SVNProjectStateStore
    var projectIdentity: SVNProjectIdentity?
    var projectStateTask: Task<Void, Never>?
    var projectStateSequence: UInt64 = 0
    var applyingProjectState = false
    var didRestoreProject = false
    var reopenMainWindow: (() -> Void)?
    let restoresProjectOnLaunch: Bool
    private var task: Task<Void, Never>?
    private var cancellable = false
    private let credentialCache: RepositoryCredentialCache
    private let ignoreConfigurationFiles: [URL]?
    private let ignorePropertyBackupDirectory: URL?
    private var loginContinuation: CheckedContinuation<SVNCredentials, Error>?
    private var listingCache = RepositoryListingCache()

    init(credentialStorage: any RepositoryCredentialStorage = KeychainRepositoryCredentialStorage(),
         ignoreConfigurationFiles: [URL]? = nil, ignorePropertyBackupDirectory: URL? = nil,
         projectStateDirectory: URL? = nil, restoresProjectOnLaunch: Bool = true) {
        credentialCache = RepositoryCredentialCache(storage: credentialStorage)
        self.ignoreConfigurationFiles = ignoreConfigurationFiles
        self.ignorePropertyBackupDirectory = ignorePropertyBackupDirectory
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        projectStateStore = SVNProjectStateStore(directory: projectStateDirectory ?? support.appendingPathComponent("SVNManager/ProjectStates", isDirectory: true))
        self.restoresProjectOnLaunch = restoresProjectOnLaunch
        executablePath = UserDefaults.standard.string(forKey: "svnExecutable") ?? SVNClient.locateExecutable() ?? ""
        repositoryHistory = RecentLocationHistory(defaults: .standard, recentKey: "recentRepositories", pinnedKey: "pinnedRepositories")
        workingCopyHistory = RecentLocationHistory(defaults: .standard, recentKey: "recentWorkingCopies", pinnedKey: "pinnedWorkingCopies")
        globalIgnorePatterns = UserDefaults.standard.stringArray(forKey: "additionalGlobalIgnores") ?? []
        showIgnoredFiles = UserDefaults.standard.bool(forKey: "showIgnoredFiles")
        repositoryURL = SVNLocation.display(recentRepositories.first ?? "")
    }

    var client: SVNClient {
        SVNClient(executablePath: executablePath, additionalGlobalIgnores: globalIgnorePatterns,
                  globalIgnoreConfigurationFiles: ignoreConfigurationFiles)
    }

    func readUserIgnoreSettings() async throws -> SVNIgnoreConfigSettings {
        let files = ignoreConfigurationFiles
        return try await Task.detached(priority: .userInitiated) {
            try SVNIgnoreConfigSettings.load(configurationFiles: files)
        }.value
    }

    func editDirectoryIgnores(at directory: URL? = nil) {
        guard !busy, let target = directory ?? workingDirectory else { return }
        directoryIgnoreRequest = DirectoryIgnoreRequest(directory: target)
    }

    func directoryIgnoreTarget(for path: String) -> (directory: URL, isSelectedDirectory: Bool)? {
        guard let directory = workingDirectory,
              let change = changes.first(where: { $0.path == path }),
              !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let target = directory.appendingPathComponent(path)
        let isDirectory = change.nodeKind == .directory && !["unversioned", "ignored", "missing", "deleted"].contains(change.item)
        return (isDirectory ? target : target.deletingLastPathComponent(), isDirectory)
    }

    func readDirectoryIgnoreSettings(at directory: URL) async throws -> SVNDirectoryIgnoreSettings {
        try await client.directoryIgnoreSettings(at: directory)
    }

    func saveDirectoryIgnoreSettings(using baseline: SVNDirectoryIgnoreSettings, ignore: String,
                                     globalIgnores: String) async throws -> DirectoryIgnoreSaveOutcome {
        guard !busy else { throw SVNError.invalid("请等待当前操作完成后再保存目录属性。") }
        busy = true
        cancellable = false
        operation = "正在保存目录忽略属性"
        defer { busy = false; cancellable = false }
        do {
            let result = try await client.saveDirectoryIgnores(using: baseline, ignore: ignore,
                globalIgnores: globalIgnores, backupDirectory: ignorePropertyBackupDirectory)
            var warning: String?
            if result.changed, let directory = workingDirectory {
                do { try await loadWorkingCopy(directory) }
                catch { warning = "目录属性已保存并读回，但列表刷新失败，请手动刷新检查。" }
            }
            operation = result.changed ? "目录忽略属性已保存在本地" : "目录忽略属性未变化"
            log(operation + "：" + result.settings.directory.path)
            if let folder = result.backupDirectory { log("目录忽略属性备份：" + folder.path) }
            if let warning { log(warning, failed: true) }
            return DirectoryIgnoreSaveOutcome(settings: result.settings, backupDirectory: result.backupDirectory,
                                               refreshWarning: warning, changed: result.changed)
        } catch {
            // A command can fail after changing one property. Refresh the list,
            // preserve its scope and leave further writes to an explicit reload.
            if let directory = workingDirectory { try? await loadWorkingCopy(directory) }
            operation = "目录忽略属性保存未完整确认"
            log(operation + "：" + error.localizedDescription, failed: true)
            throw error
        }
    }

    func saveUserIgnoreSettings(_ text: String, using baseline: SVNIgnoreConfigSettings) async throws -> UserIgnoreSaveResult {
        guard !busy else { throw SVNError.invalid("请等待当前操作完成后再保存用户全局过滤。") }
        busy = true
        cancellable = false
        operation = "正在保存 SVN 用户全局过滤"
        defer { busy = false; cancellable = false }
        do {
            let result = try await persistUserIgnoreSettings(text, using: baseline)
            operation = result.refreshWarning == nil ? "SVN 用户全局过滤已保存" : "用户配置已保存，列表待刷新"
            log(operation)
            return result
        } catch {
            operation = "保存 SVN 用户全局过滤失败"
            log(operation + "：" + error.localizedDescription, failed: true)
            throw error
        }
    }

    private func persistUserIgnoreSettings(_ text: String, using baseline: SVNIgnoreConfigSettings) async throws -> UserIgnoreSaveResult {
        let files = ignoreConfigurationFiles
        let saved = try await Task.detached(priority: .userInitiated) {
            let edit = try baseline.prepareSaving(text)
            let backup = try edit.apply()
            do {
                let settings = try SVNIgnoreConfigSettings.load(configurationFiles: files)
                guard settings.patterns == edit.remainingPatterns else {
                    throw SVNError.invalid("SVN 用户配置读回的规则与保存内容不一致。")
                }
                return (settings: settings, backup: backup)
            } catch {
                throw SVNError.invalid("用户配置已写入，但重新读取未完整确认。请重新读取并检查，勿直接重复保存。\n" + (backup.map { "原配置备份：" + $0.path } ?? ""))
            }
        }.value
        // Once the user's explicit save succeeds, all rules live in SVN's real
        // user configuration. Do not leave an invisible app-only ignore layer.
        globalIgnorePatterns = []
        UserDefaults.standard.removeObject(forKey: "additionalGlobalIgnores")
        var warning: String?
        if let directory = workingDirectory {
            do { try await loadWorkingCopy(directory) }
            catch { warning = "配置已保存并读回，但列表刷新失败，请手动刷新。" }
        }
        if let backup = saved.backup { log("SVN 用户配置备份：" + backup.path) }
        if let warning { log(warning, failed: true) }
        return UserIgnoreSaveResult(settings: saved.settings, backup: saved.backup, refreshWarning: warning)
    }

    func ignoreSuggestions(for path: String, scope: SVNIgnoreScope = .userGlobal) -> [SVNIgnoreSuggestion] {
        guard let directory = workingDirectory,
              changes.contains(where: { $0.path == path && $0.item == "unversioned" }) else { return [] }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".svn" }) else { return [] }
        let url = directory.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return scope.suggestions(forName: url.lastPathComponent,
                                 isDirectory: values.isDirectory == true && values.isSymbolicLink != true)
    }

    func ignoreUnversioned(_ path: String, using suggestion: SVNIgnoreSuggestion, scope: SVNIgnoreScope) {
        guard !busy, let directory = workingDirectory, ignoreSuggestions(for: path, scope: scope).contains(suggestion) else { return }
        run("正在忽略：\(scope.title)", canCancel: false) {
            if scope != .userGlobal {
                let result: SVNDirectoryIgnoreSaveResult
                do {
                    result = try await self.client.addDirectoryIgnore(at: directory, path: path, suggestion: suggestion,
                        scope: scope, backupDirectory: self.ignorePropertyBackupDirectory)
                } catch {
                    try? await self.loadWorkingCopy(directory)
                    throw error
                }
                do { try await self.loadWorkingCopy(directory) }
                catch { self.alert = "目录忽略属性已保存，但列表刷新失败，请手动刷新检查。" }
                if let folder = result.backupDirectory { self.log("目录忽略属性备份：" + folder.path) }
                self.log("\(scope.propertyName ?? "")：\(result.settings.directory.path)\n规则：\(suggestion.pattern)")
                return "已忽略（\(scope.title)）：\(suggestion.pattern) · 目录属性待提交"
            }
            let baseline = try await self.readUserIgnoreSettings()
            let text = (baseline.patterns + self.globalIgnorePatterns + [suggestion.pattern]).joined(separator: "\n")
            let result = try await self.persistUserIgnoreSettings(text, using: baseline)
            if let warning = result.refreshWarning { self.alert = warning }
            return "已加入 SVN 用户全局忽略：\(suggestion.pattern)"
        }
    }

    func setShowIgnoredFiles(_ value: Bool) {
        guard !busy, value != showIgnoredFiles else { return }
        showIgnoredFiles = value
        if !value && changeStatusFilter == .ignored { changeStatusFilter = .all }
        UserDefaults.standard.set(value, forKey: "showIgnoredFiles")
        if workingDirectory != nil { refresh() }
    }

    func prepareUnignore(_ path: String) {
        guard let directory = workingDirectory,
              changes.contains(where: { $0.path == path && $0.item == "ignored" }) else { return }
        run("正在检查忽略规则") {
            let plan = try await self.client.prepareUnignore(at: directory, path: path)
            self.unignoreRequest = UnignoreRequest(plan: plan)
            return "已检查忽略规则，请确认移除范围"
        }
    }

    func confirmUnignore(_ request: UnignoreRequest) {
        guard !busy else { return }
        unignoreRequest = nil
        let plan = request.plan
        guard workingDirectory == plan.directory, globalIgnorePatterns == plan.originalAppPatterns else {
            alert = "工作副本或过滤规则已变化，请刷新后重新取消忽略。"
            return
        }
        run("正在取消忽略", canCancel: false) {
            let result: SVNUnignoreResult
            do { result = try await self.client.applyUnignore(plan) }
            catch {
                try? await self.loadWorkingCopy(plan.directory)
                throw error
            }
            self.globalIgnorePatterns = plan.remainingAppPatterns
            UserDefaults.standard.set(self.globalIgnorePatterns, forKey: "additionalGlobalIgnores")
            do { try await self.loadWorkingCopy(plan.directory) }
            catch { throw SVNError.invalid("忽略规则已修改，但工作副本刷新失败，请手动刷新检查；未自动重试。") }
            if !result.propertyDirectories.isEmpty || !result.backups.isEmpty {
                var message = "已取消忽略。"
                if !result.propertyDirectories.isEmpty {
                    message += "\n以下目录的属性已在本地修改，请检查后提交：\n" + result.propertyDirectories.map(\.path).joined(separator: "\n")
                }
                if !result.backups.isEmpty {
                    let locations = Set(result.backups.map { $0.deletingLastPathComponent().path }).sorted()
                    message += "\n备份所在目录：\n" + locations.joined(separator: "\n")
                }
                self.alert = message
                self.log(message)
            }
            return "已取消忽略 · \(plan.path)"
        }
    }

    var ignoredCount: Int { changes.filter { $0.item == "ignored" }.count }
    var workingCopySummary: String {
        "\(changes.count - ignoredCount) 项变更" + (showIgnoredFiles ? " · \(ignoredCount) 项已忽略" : "")
    }

    var canChangeLogin: Bool { RepositoryCredentialScope.requiresPassword(currentURL) }
    var canCancel: Bool { busy && cancellable }
    var checkedChanges: [WorkingCopyChange] { changes.filter { checkedPaths.contains($0.path) } }
    var addablePaths: [String] {
        let checked = checkedChanges.filter { $0.item == "unversioned" }.map(\.path)
        if !checked.isEmpty { return checked }
        return changes.filter { $0.path == changeSelection && $0.item == "unversioned" }.map(\.path)
    }
    var committable: Bool { !checkedChanges.isEmpty && checkedChanges.allSatisfy(\.canCommit) }
    var filteredEntries: [RepositoryEntry] {
        let source = searchesSubdirectories ? (repositorySearchResult?.entries ?? entries) : entries
        return source.filter {
            (!repositoryDirectoriesOnly || $0.isDirectory) &&
                (searchesSubdirectories || repositorySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(repositorySearch))
        }
    }
    var repositoryListSummary: String {
        if let result = repositorySearchResult {
            let unit = repositoryDirectoriesOnly ? "个文件夹" : "项"
            return result.isTruncated ? "找到 \(result.totalMatches) \(unit) · 显示前 \(result.entries.count) 项，请缩小搜索范围" : "找到 \(result.totalMatches) \(unit)（含子目录）"
        }
        if repositoryDirectoriesOnly { return "\(entries.filter(\.isDirectory).count) 个目录" }
        return "\(entries.filter(\.isDirectory).count) 个目录 · \(entries.filter { !$0.isDirectory }.count) 个文件"
    }
    var filteredChanges: [WorkingCopyChange] {
        changeFilterResult.entries
    }

    func isRepositoryPinned(_ url: String) -> Bool { repositoryHistory.isPinned(url) }
    func isWorkingCopyPinned(_ path: String) -> Bool { workingCopyHistory.isPinned(path) }

    func toggleRepositoryPin(_ url: String) {
        repositoryHistory.togglePin(url)
        saveRepositoryHistory()
    }

    func toggleWorkingCopyPin(_ path: String) {
        workingCopyHistory.togglePin(path)
        saveWorkingCopyHistory()
    }

    private func saveRepositoryHistory() {
        repositoryHistory.save(to: .standard, recentKey: "recentRepositories", pinnedKey: "pinnedRepositories")
    }

    private func saveWorkingCopyHistory() {
        workingCopyHistory.save(to: .standard, recentKey: "recentWorkingCopies", pinnedKey: "pinnedWorkingCopies")
    }

    private func log(_ message: String, failed: Bool = false) {
        activities.insert(Activity(message: message, failed: failed), at: 0)
        activities = Array(activities.prefix(100))
    }

    func run(_ title: String, canCancel: Bool = true, cancellationMessage: String? = nil,
             action: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        busy = true
        operation = title
        cancellable = canCancel
        task = Task {
            defer { busy = false; cancellable = false; task = nil }
            do {
                let message = try await action()
                operation = message
                log(message)
            } catch is CancellationError {
                operation = "操作已取消"
                log(cancellationMessage ?? "操作已取消；签出或更新可能已处理部分文件，请刷新检查。")
            } catch {
                operation = title + "失败"
                alert = error.localizedDescription
                log(title + "失败：" + error.localizedDescription, failed: true)
            }
        }
    }

    func cancel() {
        if canCancel { task?.cancel(); cancelLogin() }
    }

    func submitLogin(username: String, password: String) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty, !password.contains("\n"), !password.contains("\r") else { return }
        let continuation = loginContinuation
        loginContinuation = nil
        loginRequest = nil
        continuation?.resume(returning: SVNCredentials(username: username, password: password))
    }

    func cancelLogin() {
        let continuation = loginContinuation
        loginContinuation = nil
        loginRequest = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func requestLogin(url: String, username: String = "", reason: String = "首次访问此仓库，请输入账号密码。") async throws -> SVNCredentials {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            loginContinuation = continuation
            loginRequest = RepositoryLoginRequest(url: url, username: username, reason: reason)
        }
    }

    /// Authenticate with a read before a write; a commit itself is never retried.
    func authenticatedClient(for url: String, forceLogin: Bool = false, verifyBeforeUse: Bool = true) async throws -> SVNClient {
        let target = try RepositoryCredentialScope.canonicalURL(url)
        guard RepositoryCredentialScope.requiresPassword(target) else { return client }
        let saved: SVNCredentials?
        do { saved = try credentialCache.credentials(for: target) }
        catch {
            // A locked or unavailable Keychain must not silently select another repository's account.
            let entered = try await requestLogin(url: target, reason: "无法读取已保存的账号。请输入账号密码，连接成功后将重新保存。")
            return try await validateLogin(entered, for: target, persist: true)
        }
        if forceLogin || saved == nil {
            let entered = try await requestLogin(url: target, username: saved?.username ?? "",
                reason: forceLogin ? "输入新的仓库账号，验证成功后替换已保存的登录信息。" : "首次访问此仓库，请输入账号密码。")
            return try await validateLogin(entered, for: target, persist: true)
        }
        // A directory read authenticates itself. Avoid a separate network `svn info`
        // on every double click when this repository already has scoped credentials.
        if !verifyBeforeUse, let saved {
            return SVNClient(executablePath: executablePath, credentials: saved, additionalGlobalIgnores: globalIgnorePatterns,
                             globalIgnoreConfigurationFiles: ignoreConfigurationFiles)
        }
        return try await validateLogin(saved!, for: target, persist: false)
    }

    private func validateLogin(_ initial: SVNCredentials, for target: String, persist: Bool) async throws -> SVNClient {
        var credentials = initial
        var shouldPersist = persist
        while true {
            try Task.checkCancellation()
            let connection = SVNClient(executablePath: executablePath, credentials: credentials,
                                       additionalGlobalIgnores: globalIgnorePatterns,
                                       globalIgnoreConfigurationFiles: ignoreConfigurationFiles)
            let identity: RepositoryIdentity
            do { identity = try await connection.repositoryInfo(url: target) }
            catch let error as SVNError where error.isAuthenticationFailure {
                credentials = try await requestLogin(url: target, username: credentials.username,
                    reason: "账号密码未通过验证，请重新输入。")
                shouldPersist = true
                continue
            }
            guard RepositoryCredentialScope.contains(root: identity.rootURL, url: target) else {
                throw SVNError.invalid("服务器返回的仓库根地址与访问地址不一致，未保存账号。请检查仓库地址。")
            }
            if shouldPersist {
                listingCache.invalidateAll()
                do { try credentialCache.remember(credentials, repositoryRoot: identity.rootURL) }
                catch {
                    // Keep the successful connection and in-memory credentials, report persistence separately.
                    alert = "仓库账号已验证，但未能持久保存。\n\(error.localizedDescription)"
                }
            }
            return connection
        }
    }

    private func authenticatedWorkingClient(at directory: URL) async throws -> SVNClient {
        let info = try await client.info(at: directory)
        return try await authenticatedClient(for: info.url)
    }

    func browse(_ url: String? = nil, forceLogin: Bool = false, forceReload: Bool = false) {
        guard !busy else { return }
        let value = url ?? repositoryURL
        let normalized: String
        do { normalized = try RepositoryCredentialScope.canonicalURL(value) }
        catch { alert = error.localizedDescription; return }
        if forceLogin { listingCache.invalidateAll() }
        if !forceLogin, !forceReload, let items = listingCache.entries(for: normalized) {
            displayRepository(items, url: normalized)
            operation = "已打开最近目录 · \(items.count) 个项目"
            return
        }
        loadingRepositoryURL = normalized
        run("正在读取仓库") {
            defer { self.loadingRepositoryURL = nil }
            let connection = try await self.authenticatedClient(for: normalized, forceLogin: forceLogin, verifyBeforeUse: false)
            let items: [RepositoryEntry]
            do { items = try await connection.list(url: normalized) }
            catch let error as SVNError where error.isAuthenticationFailure {
                // Only a failed read can be repeated after a new, explicit login.
                let replacement = try await self.authenticatedClient(for: normalized, forceLogin: true)
                items = try await replacement.list(url: normalized)
            }
            self.listingCache.store(items, for: normalized)
            self.displayRepository(items, url: normalized)
            return "已读取仓库 · \(items.count) 个项目"
        }
    }

    private func displayRepository(_ items: [RepositoryEntry], url: String) {
        currentURL = url
        repositoryURL = SVNLocation.display(url)
        entries = items
        clearRepositorySearch()
        screen = .repository
        repositoryHistory.remember(url)
        saveRepositoryHistory()
    }

    func clearRepositorySearch() {
        repositorySearch = ""
        repositorySearchResult = nil
        completedRepositorySearch = nil
    }

    func repositorySearchScopeChanged() {
        repositorySearchResult = nil
        completedRepositorySearch = nil
    }

    func repositoryDirectoriesOnlyChanged() {
        let hadResults = repositorySearchResult != nil
        repositorySearchScopeChanged()
        if hadResults && searchesSubdirectories { searchRepository() }
    }

    func searchRepository() {
        guard !busy, searchesSubdirectories, !currentURL.isEmpty else { return }
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearRepositorySearch(); return }
        let base = currentURL
        let directoriesOnly = repositoryDirectoriesOnly
        isSearchingRepository = true
        run("正在搜索子目录", cancellationMessage: "子目录搜索已取消，未修改仓库或本地文件。") {
            defer { self.isSearchingRepository = false }
            let connection = try await self.authenticatedClient(for: base, verifyBeforeUse: false)
            let result: RepositorySearchResult
            do { result = try await connection.search(url: base, query: query, directoriesOnly: directoriesOnly) }
            catch let error as SVNError where error.isAuthenticationFailure {
                let replacement = try await self.authenticatedClient(for: base, forceLogin: true)
                result = try await replacement.search(url: base, query: query, directoriesOnly: directoriesOnly)
            }
            try Task.checkCancellation()
            self.repositorySearchResult = result
            self.completedRepositorySearch = query
            return "搜索完成 · 找到 \(result.totalMatches) 项"
        }
    }

    func revealRepositoryEntry(_ entry: RepositoryEntry) {
        do {
            let location = try SVNLocation.child(entry.name, of: currentURL)
            browse(try SVNLocation.parent(of: location))
        } catch { alert = error.localizedDescription }
    }

    func openEntry(_ entry: RepositoryEntry) {
        guard entry.isDirectory else { return }
        do { browse(try SVNLocation.child(entry.name, of: currentURL)) }
        catch { alert = error.localizedDescription }
    }

    func goUp() {
        do { browse(try SVNLocation.parent(of: currentURL)) }
        catch { alert = error.localizedDescription }
    }

    func checkout(_ entry: RepositoryEntry? = nil) {
        guard !busy else { return }
        let remote: String
        do {
            remote = try entry.flatMap { $0.isDirectory ? try SVNLocation.child($0.name, of: currentURL) : nil } ?? currentURL
        } catch { alert = error.localizedDescription; return }
        guard !remote.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "选择签出目录"
        panel.message = "代码将直接签出到所选目录。目录非空时会先确认是否覆盖同名文件，其他原有文件会保留。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "签出到此目录"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        checkout(remote: remote, destination: destination)
    }

    func checkout(remote: String, destination: URL) {
        run("正在签出代码") {
            let inspection = Task.detached(priority: .userInitiated) { try SVNCheckoutDestination.isNonempty(destination) }
            let nonempty = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
            if nonempty, !(try await self.confirmCheckoutOverwrite(at: destination)) {
                return "已取消签出，目标目录未改动。"
            }
            try Task.checkCancellation()
            let progress = CheckoutProgressModel(remote: remote, destination: destination)
            self.checkoutProgress = progress
            progress.startUpdates()
            do {
                // The progress preparation itself authenticates with reads before checkout.
                var connection = try await self.authenticatedClient(for: remote, verifyBeforeUse: false)
                let plan: CheckoutPlan
                do { plan = try await connection.prepareCheckout(url: remote, destination: destination, overwriteExisting: nonempty) }
                catch let error as SVNError where error.isAuthenticationFailure {
                    // Reauthenticate only during read-only planning. Never replay checkout.
                    connection = try await self.authenticatedClient(for: remote, forceLogin: true)
                    plan = try await connection.prepareCheckout(url: remote, destination: destination, overwriteExisting: nonempty)
                }
                try await connection.checkout(plan: plan, destination: destination) { progress.receive($0) }
                // Never retry checkout after local inspection errors.
                do { try await self.loadWorkingCopy(destination) }
                catch { throw SVNError.invalid("签出命令已成功，目录：\(destination.path)\n本地状态读取失败，请打开该工作副本检查。\n\(error.localizedDescription)") }
                self.screen = .workingCopy
                progress.finish()
                return "签出完成 · \(destination.lastPathComponent)"
            } catch {
                progress.finish(error: error)
                throw error
            }
        }
    }

    private func confirmCheckoutOverwrite(at destination: URL) async throws -> Bool {
        try Task.checkCancellation()
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            throw SVNError.invalid("请先打开主窗口，再选择签出目录。")
        }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "目标目录不是空目录"
        confirmation.informativeText = "\(destination.path)\n\n是否继续签出，并用仓库版本覆盖同名文件？其他原有文件和文件夹将保留，不会清空目录。文件与文件夹类型冲突时会停止并提示处理。"
        confirmation.addButton(withTitle: "覆盖同名文件并签出")
        confirmation.addButton(withTitle: "取消")
        let accepted = await withCheckedContinuation { continuation in
            confirmation.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
        try Task.checkCancellation()
        return accepted
    }

    func chooseWorkingCopy() {
        let panel = NSOpenPanel()
        panel.title = "打开 SVN 工作副本"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "打开工作副本"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkingCopy(url)
    }

    func openWorkingCopy(_ url: URL) {
        run("正在读取工作副本") {
            try await self.loadWorkingCopy(url)
            self.screen = .workingCopy
            return "已打开工作副本 · \(url.lastPathComponent)"
        }
    }

    private func loadWorkingCopy(_ directory: URL) async throws {
        try await persistProjectState()
        let info = try await client.info(at: directory)
        // Keep the explicitly chosen scope rather than silently broadening to the WC root.
        let items = try await client.status(at: directory, showIgnored: showIgnoredFiles, includeNodeKinds: true)
        let identity = try SVNProjectIdentity(directory: directory, repositoryRootURL: info.repositoryRootURL, directoryURL: info.url)
        let sameDirectory = projectIdentity == identity
        let restored = sameDirectory ? nil : try await projectStateStore.load(identity: identity)
        let search = sameDirectory ? changeSearch : restored?.changeSearch ?? ""
        let status = sameDirectory ? changeStatusFilter : restored?.statusFilter ?? .all
        let effectiveStatus = !showIgnoredFiles && status == .ignored ? WorkingCopyStatusFilter.all : status
        let kind = sameDirectory ? changeKindFilter : restored?.kindFilter ?? .all
        let filtering = Task.detached(priority: .userInitiated) {
            try WorkingCopyFilterResult.evaluate(items, query: search, status: effectiveStatus, kind: kind)
        }
        let snapshot = try await withTaskCancellationHandler { try await filtering.value } onCancel: { filtering.cancel() }
        try Task.checkCancellation()
        applyingProjectState = true
        defer { applyingProjectState = false; scheduleProjectStateSave() }
        changeFilterTask?.cancel(); changeFilterTask = nil; changeFilterID = UUID()
        workingDirectory = directory
        workingInfo = info
        changes = items
        changeFilterResult = snapshot
        isFilteringChanges = false
        projectIdentity = identity
        let available = Set(items.filter { $0.item != "ignored" }.map(\.path))
        checkedPaths = (sameDirectory ? checkedPaths : restored?.checkedPaths ?? []).intersection(available)
        let selection = sameDirectory ? changeSelection : restored?.changeSelection
        changeSelection = items.contains(where: { $0.path == selection }) ? selection : nil
        if !sameDirectory {
            commitMessage = restored?.commitMessage ?? ""
            changeSearch = search
            changeStatusFilter = effectiveStatus
            changeKindFilter = kind
        }
        UserDefaults.standard.set(directory.path, forKey: "lastWorkingScope")
        workingCopyHistory.remember(directory.path)
        saveWorkingCopyHistory()
    }

    func refresh() {
        guard let directory = workingDirectory else { return }
        run("正在刷新变更") {
            try await self.loadWorkingCopy(directory)
            return "已刷新 · \(self.workingCopySummary)"
        }
    }

    func add(paths requestedPaths: [String]) {
        guard let directory = workingDirectory else { return }
        let requested = Set(requestedPaths)
        let paths = changes.filter { requested.contains($0.path) && $0.item == "unversioned" }.map(\.path)
        guard !paths.isEmpty else { return }
        run("正在添加到版本控制", canCancel: false) {
            do { _ = try await self.client.add(at: directory, paths: paths) }
            catch {
                try? await self.loadWorkingCopy(directory)
                self.checkedPaths.subtract(paths)
                throw SVNError.invalid("添加未完整确认，部分路径可能已经添加。请刷新检查当前状态后再操作。\n\(error.localizedDescription)")
            }
            try await self.refreshAfterWrite(directory, result: "添加已执行")
            self.checkedPaths.subtract(paths)
            return "已添加到版本控制，请检查新增清单并重新勾选提交项"
        }
    }

    func markMissing() {
        guard let directory = workingDirectory else { return }
        let paths = checkedChanges.filter { $0.item == "missing" }.map(\.path)
        guard !paths.isEmpty else { return }
        run("正在标记删除", canCancel: false) {
            do { _ = try await self.client.scheduleMissing(at: directory, paths: paths) }
            catch {
                try? await self.loadWorkingCopy(directory)
                throw SVNError.invalid("删除标记未完整确认，部分路径可能已经处理。请刷新检查当前状态后再操作。\n\(error.localizedDescription)")
            }
            try await self.refreshAfterWrite(directory, result: "删除标记已执行")
            return "已将缺失路径标记为待删除，请检查后提交"
        }
    }

    func update() {
        guard !busy, let directory = workingDirectory else { return }
        let progress = OperationProgressModel(kind: .update, directory: directory)
        operationProgress = progress
        progress.startUpdates()
        run("正在更新工作副本") {
            do {
                let connection = try await self.authenticatedWorkingClient(at: directory)
                do { _ = try await connection.updateWithProgress(at: directory) { progress.receive($0) } }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try? await self.loadWorkingCopy(directory)
                    throw SVNError.invalid("更新未完整完成，本地可能已有部分更新或冲突。请检查工作副本状态。\n\(error.localizedDescription)")
                }
                try await self.refreshAfterWrite(directory, result: "更新命令已完成")
                let conflicts = self.changes.filter { $0.treeConflicted || $0.item == "conflicted" || $0.properties == "conflicted" }.count
                let summary = conflicts > 0 ? "更新完成 · \(conflicts) 项冲突需要处理" : "更新完成"
                progress.finish(summary: summary, warning: conflicts > 0)
                return summary
            } catch {
                progress.finish(error: error)
                throw error
            }
        }
    }

    func previewDiff() {
        guard let directory = workingDirectory, let path = changeSelection,
              let change = changes.first(where: { $0.path == path }) else { return }
        if ["unversioned", "ignored"].contains(change.item) { alert = "该文件尚未纳入版本控制。已忽略项须先取消忽略，再 Add 后查看新增差异。"; return }
        run("正在读取差异") {
            if self.canCompareWithCloud(path) {
                let target = try await self.client.prepareRemoteFileDiff(at: directory, path: path)
                let files = try await self.client.fileComparison(target, revision: .base)
                self.fileDiff = try await self.prepareFilePresentation(files, path: path)
                self.diffFileTarget = target
                self.diffRevisionChoice = "base"
                self.diffText = ""
                self.diffContext = "本地文件与签出基线（BASE）的内容比较。颜色表示本地相对基线的变化。"
            } else {
                let text = try await self.client.diff(at: directory, paths: [path])
                self.fileDiff = nil
                self.diffFileTarget = nil
                self.diffText = text.isEmpty ? "没有可显示的文本差异。该项可能只有目录或元数据变化。" : text
                self.diffContext = "签出基线（BASE）→ 本地工作副本。"
            }
            try Task.checkCancellation()
            self.diffTitle = path
            self.showDiff = true
            return "差异已就绪"
        }
    }

    func canCompareWithCloud(_ path: String) -> Bool {
        guard let change = changes.first(where: { $0.path == path }) else { return false }
        return !change.treeConflicted && [.file, .symbolicLink].contains(change.nodeKind) &&
            ["normal", "none", "modified", "replaced", "conflicted"].contains(change.item)
    }

    func previewCloudDiff(_ path: String) {
        guard !busy, let directory = workingDirectory, canCompareWithCloud(path) else { return }
        run("正在读取云端文件差异", cancellationMessage: "文件差异比较已取消。") {
            let target = try await self.client.prepareRemoteFileDiff(at: directory, path: path)
            let connection = try await self.authenticatedClient(for: target.url, verifyBeforeUse: false)
            let files: SVNFileComparison
            do { files = try await connection.fileComparison(target) }
            catch let error as SVNError where error.isAuthenticationFailure {
                let replacement = try await self.authenticatedClient(for: target.url, forceLogin: true)
                files = try await replacement.fileComparison(target)
            }
            let presentation = try await self.prepareFilePresentation(files, path: path)
            try Task.checkCancellation()
            self.diffTitle = path
            self.diffContext = "本地文件与云端最新版本的内容比较。颜色表示本地相对云端的变化。"
            self.diffText = ""
            self.fileDiff = presentation
            self.diffFileTarget = target
            self.diffRevisionChoice = "head"
            self.showDiff = true
            return "云端差异已就绪 · \(path)"
        }
    }

    func prepareFilePresentation(_ files: SVNFileComparison, path: String = "") async throws -> FileDiffPresentation {
        let worker = Task.detached(priority: .userInitiated) {
            let lines = try SVNLineComparison.compare(local: files.local.text, remote: files.remote.text)
            let decorations = try SVNComparisonDecorations.prepare(rows: lines.rows)
            var starts: [Int] = []
            var previousChanged = false
            var localColumns = 0
            var remoteColumns = 0
            func columns(_ text: String?) -> Int {
                guard let text else { return 0 }
                var count = 0
                for character in text.prefix(8_192) {
                    if character == "\t" { count += 4 - count % 4 }
                    else {
                        let scalar = character.unicodeScalars.first?.value ?? 0
                        count += character.utf16.count > 1 || scalar >= 0x2E80 || (0x1100...0x11FF).contains(scalar) ? 2 : 1
                    }
                }
                return count
            }
            for (index, row) in lines.rows.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let changed = row.change != .unchanged
                if changed && !previousChanged { starts.append(index) }
                previousChanged = changed
                localColumns = max(localColumns, columns(row.localText))
                remoteColumns = max(remoteColumns, columns(row.remoteText))
            }
            return FileDiffPresentation(files: files, lines: lines, changeStarts: starts,
                                        localColumns: localColumns, remoteColumns: remoteColumns,
                                        decorations: decorations, language: (path as NSString).pathExtension.lowercased())
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func commit() {
        guard !busy, let directory = workingDirectory, committable else { return }
        let paths = checkedChanges.map(\.path)
        let message = commitMessage
        showCommit = false
        let progress = OperationProgressModel(kind: .commit, directory: directory)
        operationProgress = progress
        progress.startUpdates()
        run("正在提交变更", canCancel: false) {
            do {
                let connection = try await self.authenticatedWorkingClient(at: directory)
                let result: SVNOperationResult
                do { result = try await connection.commitWithProgress(at: directory, paths: paths, message: message) { progress.receive($0) } }
                catch {
                    throw SVNError.invalid("提交未确认成功。网络中断时服务器可能已接收提交，请先刷新并核对仓库版本，再决定后续操作。\n\(error.localizedDescription)")
                }
                self.commitMessage = ""
                self.checkedPaths = []
                self.listingCache.invalidateAll()
                try await self.refreshAfterWrite(directory, result: "SVN 已确认提交成功")
                let summary = result.revision.map { "提交成功 · r\($0) · \(paths.count) 项" } ?? "提交成功 · \(paths.count) 项"
                progress.finish(summary: summary)
                return summary
            } catch {
                progress.finish(error: error)
                throw error
            }
        }
    }

    private func refreshAfterWrite(_ directory: URL, result: String) async throws {
        do { try await loadWorkingCopy(directory) }
        catch { throw SVNError.invalid("\(result)，但状态刷新失败；请手动刷新核实，不要重复执行。\n\(error.localizedDescription)") }
    }

    func revealWorkingCopy() {
        if let directory = workingDirectory { NSWorkspace.shared.open(directory) }
    }

    func clearRecentHistory() {
        repositoryHistory.clearRecent()
        workingCopyHistory.clearRecent()
        saveRepositoryHistory()
        saveWorkingCopyHistory()
    }
}
