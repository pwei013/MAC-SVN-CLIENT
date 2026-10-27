import Foundation
import SVNCore

struct HistorySession: Identifiable {
    let id = UUID()
    let url: String
    let repositoryRoot: String
    let client: SVNClient
    let page: SVNHistoryPage
    let byteCost: Int
}

struct IncomingSession: Identifiable {
    let id = UUID()
    let directory: URL
    let client: SVNClient
    let report: SVNIncomingUpdateReport
}

extension AppModel {
    func openHistory(url requestedURL: String? = nil) {
        let url = requestedURL ?? (screen == .workingCopy ? workingInfo?.url : currentURL)
        guard !busy, let url, !url.isEmpty else { return }
        run("正在读取提交历史", cancellationMessage: "历史读取已取消。") {
            self.historySession = try await self.readHistorySession(url: url)
            return "已读取提交历史"
        }
    }

    func readHistorySession(url: String) async throws -> HistorySession {
        var connection = try await authenticatedClient(for: url, verifyBeforeUse: false)
        var identity: RepositoryIdentity
        let page: SVNHistoryPage
        do {
            identity = try await connection.repositoryInfo(url: url)
            page = try await connection.history(url: url)
        } catch let error as SVNError where error.isAuthenticationFailure {
            connection = try await authenticatedClient(for: url, forceLogin: true)
            identity = try await connection.repositoryInfo(url: url)
            page = try await connection.history(url: url)
        }
        try Task.checkCancellation()
        let cost = await Task.detached(priority: .userInitiated) { historyPageCost(page.entries) }.value
        try Task.checkCancellation()
        return HistorySession(url: url, repositoryRoot: identity.rootURL, client: connection, page: page, byteCost: cost)
    }

    func openWorkingHistory(_ path: String? = nil) {
        guard !busy, let directory = workingDirectory else { return }
        run("正在读取提交历史", cancellationMessage: "历史读取已取消。") {
            let url = try await self.client.workingHistoryURL(at: directory, path: path ?? ".")
            self.historySession = try await self.readHistorySession(url: url)
            return "已读取提交历史"
        }
    }

    func checkIncomingUpdates() {
        guard !busy, let directory = workingDirectory, workingInfo != nil else { return }
        showCommit = false
        run("正在检查云端更新", cancellationMessage: "云端检查已取消，本地文件未更新。") {
            try await self.readIncomingUpdates(at: directory)
        }
    }

    func readIncomingUpdates(at directory: URL) async throws -> String {
        let info = try await client.info(at: directory)
        var connection = try await authenticatedClient(for: info.url, verifyBeforeUse: false)
        let report: SVNIncomingUpdateReport
        do { report = try await connection.incomingUpdates(at: directory) }
        catch let error as SVNError where error.isAuthenticationFailure {
            connection = try await authenticatedClient(for: info.url, forceLogin: true)
            report = try await connection.incomingUpdates(at: directory)
        }
        try Task.checkCancellation()
        incomingSession = IncomingSession(directory: directory, client: connection, report: report)
        return "云端更新检查完成 · \(report.entries.count) 项，本地文件未更新"
    }

    func reloadFileDiff(choice: String, revisionText: String) {
        guard let target = diffFileTarget else { return }
        let revision: SVNFileComparisonRevision
        switch choice {
        case "base": revision = .base
        case "head": revision = .head
        default:
            let input = revisionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, input.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int64(input), number > 0 else { diffError = "请输入有效的数字版本号，例如 123。"; return }
            revision = .revision(number)
        }
        cancelDiffRead()
        let request = UUID()
        diffReadID = request
        diffReloading = true
        diffError = nil
        diffReadTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.diffReadID == request { self.diffReloading = false; self.diffReadTask = nil } }
            do {
                let files: SVNFileComparison
                if choice == "base" { files = try await self.client.fileComparison(target, revision: revision) }
                else {
                    let connection = try await self.authenticatedClient(for: target.url, verifyBeforeUse: false)
                    do { files = try await connection.fileComparison(target, revision: revision) }
                    catch let error as SVNError where error.isAuthenticationFailure {
                        let replacement = try await self.authenticatedClient(for: target.url, forceLogin: true)
                        files = try await replacement.fileComparison(target, revision: revision)
                    }
                }
                let value = try await self.prepareFilePresentation(files, path: target.path)
                try Task.checkCancellation()
                guard self.diffReadID == request else { return }
                self.fileDiff = value
                self.diffRevisionChoice = choice
                self.diffContext = "左侧本地文件，右侧为\(files.remoteLabel)。颜色表示左侧相对右侧的变化。"
            } catch is CancellationError { }
            catch { if self.diffReadID == request { self.diffError = error.localizedDescription } }
        }
    }

    func cancelDiffRead() {
        diffReadTask?.cancel()
        if diffReadTask != nil { cancelLogin() }
        diffReadTask = nil
        diffReadID = UUID()
        diffReloading = false
    }
}
