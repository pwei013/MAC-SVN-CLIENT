import Foundation

public struct SVNClient: Sendable {
    public let executablePath: String
    public let credentials: SVNCredentials
    public let additionalGlobalIgnores: [String]
    let globalIgnoreConfigurationFiles: [URL]?
    public init(executablePath: String, credentials: SVNCredentials = .init(), additionalGlobalIgnores: [String] = [],
                globalIgnoreConfigurationFiles: [URL]? = nil) {
        self.executablePath = executablePath
        self.credentials = credentials
        self.additionalGlobalIgnores = additionalGlobalIgnores
        self.globalIgnoreConfigurationFiles = globalIgnoreConfigurationFiles
    }

    public static func locateExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/svn-cli/bin/svn", "/opt/homebrew/bin/svn", "/usr/local/bin/svn", "/usr/bin/svn"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/svn" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func execute(_ command: String, _ arguments: [String], at directory: URL? = nil,
                         authenticated: Bool = false, onStdout: (@Sendable (Data) -> Void)? = nil,
                         captureStdout: Bool = true) async throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SVNError.invalid("找不到 SVN 命令行程序，请在设置中选择已安装的 svn（推荐 1.14 或以上）。")
        }
        var args = [command, "--non-interactive", "--no-auth-cache"]
        if command == "status" || command == "add",
           let option = try SVNGlobalIgnores.configurationOption(additional: additionalGlobalIgnores,
                                                               configurationFiles: globalIgnoreConfigurationFiles) {
            args += ["--config-option", option]
        }
        var input = Data()
        if authenticated {
            if !credentials.username.isEmpty { args += ["--username", credentials.username] }
            if !credentials.password.isEmpty {
                guard !credentials.password.contains("\n"), !credentials.password.contains("\r") else {
                    throw SVNError.invalid("密码不能包含换行符。")
                }
                args.append("--password-from-stdin")
                input = Data((credentials.password + "\n").utf8)
            }
        }
        let result = try await ProcessRunner.run(executable: executablePath, arguments: args + arguments,
                                                  directory: directory, input: input, onStdout: onStdout, captureStdout: captureStdout)
        guard result.exitCode == 0 else {
            // Avoid reflecting credentials even if a server happens to echo them.
            let detail = String(decoding: result.stderr, as: UTF8.self)
            let authenticationFailed = ["E170001", "E215004", "E215003"].contains { detail.contains($0) }
            let codes = detail.components(separatedBy: .newlines).filter { $0.contains("svn:") }
            var safeDetail = codes.isEmpty ? "请检查路径、网络、认证和服务器证书。" : codes.joined(separator: "\n")
            if !credentials.password.isEmpty { safeDetail = safeDetail.replacingOccurrences(of: credentials.password, with: "[已隐藏]") }
            if authenticationFailed { throw SVNError.authentication(result.exitCode, String(safeDetail.prefix(4000))) }
            throw SVNError.command(result.exitCode, String(safeDetail.prefix(4000)))
        }
        return result
    }

    private func peg(_ path: String) -> String { path + "@" }

    func paths(_ paths: [String], at directory: URL, appendPeg: Bool = true) throws -> [String] {
        guard !paths.isEmpty else { throw SVNError.invalid("请至少选择一个文件或目录。") }
        let base = directory.standardizedFileURL.path
        return try Array(Set(paths)).sorted().map {
            guard !$0.isEmpty, !$0.hasPrefix("/"), !$0.contains("\0"),
                  !$0.split(separator: "/").contains(".."),
                  !$0.split(separator: "/").contains(".svn") else {
                throw SVNError.invalid("无效的工作副本相对路径。")
            }
            let full = directory.appendingPathComponent($0).standardizedFileURL.path
            guard full == base || full.hasPrefix(base + "/") else { throw SVNError.invalid("路径超出工作副本。") }
            return appendPeg ? peg($0) : $0
        }
    }

    public func list(url: String) async throws -> [RepositoryEntry] {
        let location = try SVNLocation.validated(url)
        return try SVNXML.parseList(await execute("list", ["--xml", "--depth", "immediates", "--", peg(location.absoluteString)], authenticated: true).stdout)
    }

    public func search(url: String, query: String, limit: Int = 5000,
                       directoriesOnly: Bool = false) async throws -> RepositorySearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SVNError.invalid("请输入要搜索的名称或相对路径。") }
        let location = try SVNLocation.validated(url)
        try Task.checkCancellation()
        let output = try await execute("list", ["--xml", "--depth", "infinity", "--", peg(location.absoluteString)], authenticated: true)
        try Task.checkCancellation()
        return try SVNXML.searchList(output.stdout, query: query, limit: limit, directoriesOnly: directoriesOnly)
    }

    public func repositoryInfo(url: String) async throws -> RepositoryIdentity {
        let location = try SVNLocation.validated(url)
        return try SVNXML.parseRepositoryInfo(await execute("info", ["--xml", "--", peg(location.absoluteString)], authenticated: true).stdout)
    }

    public func checkout(url: String, destination: URL, overwriteExisting: Bool = false) async throws -> String {
        if let existing = try await checkoutWorkingCopy(at: destination, matching: url) {
            return try await updateCheckout(existing, at: destination) { _ in }.text
        }
        if overwriteExisting {
            try await checkoutWithProgress(url: url, destination: destination, overwriteExisting: true) { _ in }
            return "签出完成，目标目录中的其他原有文件已保留。"
        }
        let location = try SVNLocation.validated(url)
        try validateCheckoutDestination(destination)
        return try await execute("checkout", ["--ignore-externals", "--", peg(location.absoluteString), destination.path], authenticated: true).text
    }

    private func validateCheckoutDestination(_ destination: URL, overwriteExisting: Bool = false) throws {
        if try SVNCheckoutDestination.isNonempty(destination), !overwriteExisting {
            throw SVNError.invalid("目标目录不是空目录，请重新选择并确认覆盖同名文件后签出。")
        }
    }

    /// Count and download one immutable revision so remote commits cannot change the denominator.
    public func checkoutWithProgress(url: String, destination: URL, overwriteExisting: Bool = false,
                                     onProgress: @escaping @Sendable (CheckoutEvent) -> Void) async throws {
        if let existing = try await checkoutWorkingCopy(at: destination, matching: url) {
            onProgress(.started(totalItems: 0, revision: existing.info.revision))
            _ = try await updateCheckout(existing, at: destination) { event in
                if case let .output(records, processed) = event {
                    onProgress(.output(lines: records.map(\.message), completedItems: processed))
                }
            }
            try Task.checkCancellation()
            onProgress(.completed)
            return
        }
        let plan = try await prepareCheckout(url: url, destination: destination, overwriteExisting: overwriteExisting)
        try await checkout(plan: plan, destination: destination, onProgress: onProgress)
    }

    public func prepareCheckout(url: String, destination: URL, overwriteExisting: Bool = false) async throws -> CheckoutPlan {
        let location = try SVNLocation.validated(url)
        try validateCheckoutDestination(destination, overwriteExisting: overwriteExisting)
        try Task.checkCancellation()
        let info = try await execute("info", ["--xml", "--", peg(location.absoluteString)], authenticated: true)
        let revision = try SVNXML.parseCheckoutRevision(info.stdout)
        let target = location.absoluteString + "@" + revision
        let listing = try await execute("list", ["--xml", "--depth", "infinity", "--revision", revision, "--", target], authenticated: true)
        let entries = try SVNXML.checkoutListing(listing.stdout)
        return CheckoutPlan(target: target, revision: revision, paths: entries.paths,
                            directories: entries.directories, overwriteExisting: overwriteExisting)
    }

    public func checkout(plan: CheckoutPlan, destination: URL,
                         onProgress: @escaping @Sendable (CheckoutEvent) -> Void) async throws {
        let tracker = CheckoutOutputTracker(destination: destination, paths: plan.paths,
                                            password: credentials.password, onProgress: onProgress)
        onProgress(.started(totalItems: plan.paths.count, revision: plan.revision))
        try Task.checkCancellation()
        // Recheck after preparation; only an explicitly confirmed checkout may merge.
        try validateCheckoutDestination(destination, overwriteExisting: plan.overwriteExisting)
        let existing = plan.overwriteExisting ? try checkoutExistingFiles(at: destination, paths: plan.paths, directories: plan.directories) : []
        var downloaded = false
        do {
            let force = plan.overwriteExisting ? ["--force"] : []
            _ = try await execute("checkout", force + ["--ignore-externals", "--revision", plan.revision, "--", plan.target, destination.path],
                                  authenticated: true, onStdout: { tracker.append($0) }, captureStdout: false)
            downloaded = true
            if !existing.isEmpty {
                tracker.append(Data("正在按仓库版本覆盖 \(existing.count) 个同名文件，其他原有文件保持不变。\n".utf8))
                // --force adopts obstructing files as local modifications. Restore
                // only those exact files from the pinned BASE; never revert a tree.
                var batch: [CheckoutExistingFile] = [], bytes = 0
                func restore(_ files: [CheckoutExistingFile]) async throws {
                    try Task.checkCancellation()
                    for file in files { try file.revalidate(at: destination) }
                    _ = try await execute("revert", ["--depth", "empty", "--"] + paths(files.map(\.path), at: destination),
                        at: destination, onStdout: { tracker.append($0) }, captureStdout: false)
                }
                for file in existing {
                    if batch.count >= 128 || bytes + file.path.utf8.count > 32 * 1_024 {
                        try await restore(batch); batch = []; bytes = 0
                    }
                    batch.append(file); bytes += file.path.utf8.count + 2
                }
                if !batch.isEmpty { try await restore(batch) }
            }
        } catch {
            tracker.finish()
            if downloaded, !(error is CancellationError) {
                throw SVNError.invalid("仓库签出已完成，但同名文件覆盖未全部完成。请打开工作副本检查，不要直接重复签出。\n\(error.localizedDescription)")
            }
            throw error
        }
        tracker.finish()
        try Task.checkCancellation()
        onProgress(.completed)
    }

    public func info(at directory: URL) async throws -> WorkingCopyInfo {
        try SVNXML.parseInfo(await execute("info", ["--xml", "--", ".@"], at: directory).stdout)
    }

    public func status(at directory: URL, showIgnored: Bool = false,
                       includeNodeKinds: Bool = false) async throws -> [WorkingCopyChange] {
        var arguments = ["--xml", "--ignore-externals"]
        if showIgnored { arguments.append("--no-ignore") }
        let changes = try SVNXML.parseStatus(await execute("status", arguments + ["--", ".@"], at: directory).stdout)
        guard includeNodeKinds else { return changes }
        return try await addingNodeKinds(to: changes, at: directory)
    }

    /// Nonisolated async work runs off the main actor. Inspect each existing path
    /// once, then consult WC metadata in one batch for missing/deleted tracked paths.
    /// Icons must never turn a successful status command into a failed refresh.
    private func addingNodeKinds(to changes: [WorkingCopyChange], at directory: URL) async throws -> [WorkingCopyChange] {
        var kinds: [String: WorkingCopyNodeKind] = [:]
        var unresolved: [String] = []
        let base = directory.standardizedFileURL.path
        let trackedItems: Set<String> = ["missing", "deleted", "modified", "added", "replaced", "normal", "none", "conflicted", "obstructed", "incomplete"]
        for change in changes {
            try Task.checkCancellation()
            let components = change.path.split(separator: "/")
            guard !change.path.isEmpty, !change.path.hasPrefix("/"), !change.path.contains("\0"),
                  !components.contains(".."), !components.contains(".svn") else { continue }
            let url = directory.appendingPathComponent(change.path).standardizedFileURL
            guard url.path == base || url.path.hasPrefix(base + "/") else { continue }
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            switch type {
            case .typeDirectory: kinds[change.path] = .directory
            case .typeRegular: kinds[change.path] = .file
            case .typeSymbolicLink: kinds[change.path] = .symbolicLink
            default:
                if trackedItems.contains(change.item) { unresolved.append(change.path) }
            }
        }
        if !unresolved.isEmpty {
            do {
                let arguments = ["--xml", "--depth", "empty", "--"] + (try paths(unresolved, at: directory))
                let entries = try SVNXML.parseWorkingCopyNodeKinds(await execute("info", arguments, at: directory).stdout)
                for path in unresolved {
                    if let kind = entries[path] { kinds[path] = kind }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Metadata is optional; retain the original list and unknown kinds. */ }
        }
        try Task.checkCancellation()
        return changes.map {
            WorkingCopyChange(path: $0.path, item: $0.item, properties: $0.properties,
                              treeConflicted: $0.treeConflicted, nodeKind: kinds[$0.path] ?? .unknown)
        }
    }

    /// Read-only preflight: verify the row is still ignored, find app-owned rules,
    /// then ask SVN itself whether removing them would actually unignore the target.
    /// Existing SVN config/properties are never changed, and no recursive scan is needed.
    public func removableIgnorePatterns(at directory: URL, path: String) async throws -> [String] {
        let targets = try paths([path], at: directory)
        let arguments = ["--xml", "--ignore-externals", "--no-ignore", "--depth", "empty", "--"] + targets
        let current = try SVNXML.parseStatus(await execute("status", arguments, at: directory).stdout)
        guard current.contains(where: { $0.item == "ignored" }) else {
            throw SVNError.invalid("该项目的忽略状态已变化，请刷新列表后重试。")
        }
        let matches = try SVNGlobalIgnores.matchingPatterns(forName: (path as NSString).lastPathComponent,
                                                          in: additionalGlobalIgnores)
        guard !matches.isEmpty else {
            throw SVNError.invalid("未找到可取消的应用全局过滤规则。该项目可能由 SVN 原有配置或目录属性忽略，请在对应 SVN 配置或目录属性中修改。")
        }
        let removed = Set(matches)
        let candidate = SVNClient(executablePath: executablePath, credentials: credentials,
                                  additionalGlobalIgnores: additionalGlobalIgnores.filter { !removed.contains($0) },
                                  globalIgnoreConfigurationFiles: globalIgnoreConfigurationFiles)
        let afterRemoval = try SVNXML.parseStatus(await candidate.execute("status", arguments, at: directory).stdout)
        guard afterRemoval.contains(where: { $0.item == "unversioned" }) else {
            throw SVNError.invalid("移除应用规则后，该项目仍受 SVN 原有忽略配置或目录属性影响，无法仅通过全局过滤取消忽略。请检查对应 SVN 配置或目录属性；本次未修改任何规则。")
        }
        return matches
    }

    public func diff(at directory: URL, paths targets: [String]) async throws -> String {
        // In diff's --old/--new form, trailing PATHs are literal relative filters,
        // whereas the two base targets accept peg syntax. This preserves literal @ names.
        try await execute("diff", ["--internal-diff", "--depth", "empty", "--old", ".@", "--new", ".@", "--revision", "BASE", "--"] +
                          paths(targets, at: directory, appendPeg: false), at: directory).text
    }

    public func add(at directory: URL, paths targets: [String]) async throws -> String {
        let validatedTargets = try paths(targets, at: directory)
        if !additionalGlobalIgnores.isEmpty {
            // SVN normally lets an explicit add target bypass ignores. Recheck
            // selected paths and their ancestors so a stale selection cannot do so.
            let ancestors = Set(targets.flatMap { path -> [String] in
                let components = path.split(separator: "/")
                return (1...components.count).map { components.prefix($0).joined(separator: "/") }
            })
            let output = try await execute("status", ["--xml", "--ignore-externals", "--depth", "empty", "--"] +
                                           paths(Array(ancestors), at: directory), at: directory)
            guard !(try SVNXML.parseStatus(output.stdout)).contains(where: { $0.item == "ignored" }) else {
                throw SVNError.invalid("所选项目或其上级目录已被 SVN 忽略，请刷新列表后重新选择。")
            }
        }
        return try await execute("add", ["--parents", "--depth", "infinity", "--"] + validatedTargets, at: directory).text
    }

    public func scheduleMissing(at directory: URL, paths targets: [String]) async throws -> String {
        let changes = try await status(at: directory)
        guard targets.allSatisfy({ path in changes.contains { $0.path == path && $0.item == "missing" && !$0.treeConflicted } }) else {
            throw SVNError.invalid("仅允许将当前确实缺失且没有冲突的路径标记为删除。")
        }
        return try await execute("delete", ["--",] + paths(targets, at: directory), at: directory).text
    }

    public func commit(at directory: URL, paths targets: [String], message: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SVNError.invalid("请填写提交说明。")
        }
        let current = try await status(at: directory)
        guard targets.allSatisfy({ path in current.contains { $0.path == path && $0.canCommit } }) else {
            throw SVNError.invalid("勾选项状态已变化或无法提交，请刷新后重新检查。")
        }
        // Commit every explicit target at depth empty: an unchecked child is never swept in.
        return try await execute("commit", ["--depth", "empty", "--message", message, "--"] + paths(targets, at: directory), at: directory, authenticated: true).text
    }

    public func update(at directory: URL) async throws -> String {
        try await execute("update", ["--ignore-externals", "--accept", "postpone", "--", ".@"], at: directory, authenticated: true).text
    }
}
