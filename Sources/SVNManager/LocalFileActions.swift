import AppKit
import SVNCore

enum LocalFileApplication {
    case finder, visualStudioCode
}

extension AppModel {
    func openLocalChange(_ path: String, using application: LocalFileApplication) {
        guard !busy, let directory = workingDirectory,
              changes.contains(where: { $0.path == path }),
              !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { return }
        let target = directory.appendingPathComponent(path).standardizedFileURL
        Task { [weak self] in
            do {
                // Keep filesystem access out of menu construction and row selection.
                let isDirectory = try await Task.detached(priority: .userInitiated) {
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) else {
                        throw SVNError.invalid("本地文件或文件夹已不存在或无法访问，请刷新列表后重试。")
                    }
                    return attributes[.type] as? FileAttributeType == .typeDirectory
                }.value
                let workspace = NSWorkspace.shared
                if application == .finder && !isDirectory {
                    workspace.activateFileViewerSelecting([target])
                    return
                }
                let identifier = application == .finder ? "com.apple.finder" : "com.microsoft.VSCode"
                guard let app = workspace.urlForApplication(withBundleIdentifier: identifier) else {
                    self?.alert = application == .finder ? "未找到访达。" : "未找到 Visual Studio Code，请先安装后重试。"
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                workspace.open([target], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in
                        self?.alert = application == .finder ? "无法在访达中打开所选目录，请确认目录仍可访问。" :
                            "无法在 VS Code 中打开所选文件或文件夹，请确认应用及路径仍可访问。"
                    }
                }
            } catch {
                self?.alert = error.localizedDescription
            }
        }
    }
}
