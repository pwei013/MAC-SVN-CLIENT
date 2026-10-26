import Foundation
import SVNCore

extension AppModel {
    private func projectSnapshot() -> SVNProjectState {
        SVNProjectState(commitMessage: commitMessage, checkedPaths: checkedPaths,
                        changeSearch: changeSearch, changeSelection: changeSelection,
                        statusFilter: changeStatusFilter, kindFilter: changeKindFilter)
    }

    func scheduleProjectStateSave() {
        guard !applyingProjectState, let identity = projectIdentity else { return }
        projectStateTask?.cancel()
        projectStateSequence &+= 1
        let sequence = projectStateSequence
        let snapshot = projectSnapshot()
        let store = projectStateStore
        projectStateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                _ = try await store.save(snapshot, identity: identity, sequence: sequence)
                if self?.projectIdentity == identity { self?.projectStateWarning = nil }
            } catch is CancellationError { }
            catch { self?.projectStateWarning = "项目草稿尚未保存：\(error.localizedDescription)" }
        }
    }

    func persistProjectState() async throws {
        projectStateTask?.cancel()
        projectStateTask = nil
        guard let identity = projectIdentity else { return }
        projectStateSequence &+= 1
        do {
            _ = try await projectStateStore.save(projectSnapshot(), identity: identity, sequence: projectStateSequence)
            projectStateWarning = nil
        } catch {
            projectStateWarning = "项目草稿尚未保存：\(error.localizedDescription)"
            throw error
        }
    }

    func flushProjectStateForTermination() async -> Bool {
        do { try await persistProjectState(); return true }
        catch {
            alert = "项目草稿保存失败，已取消退出。请检查磁盘权限或空间后重试。\n\(error.localizedDescription)"
            return false
        }
    }

    func restoreLastProjectIfNeeded() {
        guard !didRestoreProject else { return }
        didRestoreProject = true
        guard restoresProjectOnLaunch, !busy, workingDirectory == nil,
              let saved = UserDefaults.standard.string(forKey: "lastWorkingScope"),
              saved.hasPrefix("/") else { return }
        openWorkingCopy(URL(fileURLWithPath: saved, isDirectory: true))
    }
}
