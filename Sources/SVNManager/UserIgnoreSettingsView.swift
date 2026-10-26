import SwiftUI
import SVNCore

struct UserIgnoreSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var settings: SVNIgnoreConfigSettings?
    @State private var rules = ""
    @State private var loading = false
    @State private var feedback = ""
    @State private var failed = false

    private var hasChanges: Bool {
        guard let settings else { return false }
        return rules != settings.patterns.joined(separator: "\n") || !model.globalIgnorePatterns.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SVN 用户全局过滤").font(.headline)
            Text("读取并编辑 SVN 用户配置中的 global-ignores。保存后，使用此配置的其他 SVN 客户端也会生效。")
                .font(.callout).foregroundStyle(.secondary)
            if let settings {
                Text(settings.file.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(settings.sourceDescription).font(.caption).foregroundStyle(.secondary)
            }
            if !model.globalIgnorePatterns.isEmpty {
                Text("已带入旧版工具规则：\(model.globalIgnorePatterns.joined(separator: "、"))。保存后统一迁移到 SVN 用户配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("每行一个名称或通配符，例如 bin、obj、*.log；名称中的空格可用 ? 匹配。清空并保存会关闭用户级全局过滤。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $rules).font(.system(size: 12, design: .monospaced))
                .frame(height: 150).border(Color.secondary.opacity(0.25))
                .accessibilityLabel("SVN 用户全局过滤规则")
                .disabled(loading || model.busy || settings == nil)
            HStack {
                Button("重新读取") { Task { await load() } }.disabled(loading || model.busy)
                    .help("从 SVN 用户配置重新载入，放弃尚未保存的编辑。")
                Spacer()
                Button("保存到用户配置") { Task { await save() } }
                    .disabled(loading || model.busy || !hasChanges)
            }
            if loading { ProgressView("正在读取 SVN 用户配置…").controlSize(.small) }
            if model.busy { ProgressView("正在保存并刷新…").controlSize(.small) }
            if !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled)
            }
            Text("目录的 svn:ignore / svn:global-ignores 仍独立生效，可在工作副本的“目录忽略属性”中显示和编辑。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard !loading, !model.busy else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await model.readUserIgnoreSettings()
            guard !Task.isCancelled else { return }
            settings = value
            var seen = Set<String>()
            rules = (value.patterns + model.globalIgnorePatterns).filter { seen.insert($0).inserted }.joined(separator: "\n")
            failed = false
            feedback = ""
        } catch {
            settings = nil
            failed = true
            feedback = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let settings, !loading, !model.busy else { return }
        feedback = ""
        do {
            let result = try await model.saveUserIgnoreSettings(rules, using: settings)
            self.settings = result.settings
            rules = result.settings.patterns.joined(separator: "\n")
            failed = result.refreshWarning != nil
            feedback = result.refreshWarning ?? "已保存到 SVN 用户配置并读回确认。"
            if let backup = result.backup { feedback += "\n原配置备份：" + backup.path }
        } catch {
            failed = true
            feedback = error.localizedDescription
        }
    }
}
