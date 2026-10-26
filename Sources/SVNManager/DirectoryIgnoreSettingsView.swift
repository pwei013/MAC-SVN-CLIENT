import AppKit
import SwiftUI
import SVNCore

struct DirectoryIgnoreSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var directory: URL
    @State private var settings: SVNDirectoryIgnoreSettings?
    @State private var ignore = ""
    @State private var globalIgnores = ""
    @State private var loading = false
    @State private var requiresReload = false
    @State private var feedback = ""
    @State private var failed = false
    @State private var pendingDirectory: URL?
    @State private var closing = false
    @State private var confirmDiscard = false

    init(model: AppModel, directory: URL) {
        self.model = model
        _directory = State(initialValue: directory)
    }

    private var changed: Bool {
        guard let settings else { return false }
        return ignore != (settings.ignore ?? "") || globalIgnores != (settings.globalIgnores ?? "")
    }

    private var unavailable: Bool { loading || model.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("目录忽略属性").font(.title2.bold())
                Spacer()
                Button("选择目录…", action: chooseDirectory).disabled(unavailable)
            }
            Text(directory.path).font(.system(.callout, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("仅影响未跟踪项；每行一个名称或通配符（*、?、[abc]），名称中的空格按字面匹配。")
                        .font(.callout).foregroundStyle(.secondary)
                    propertyEditor("svn:ignore", value: $ignore,
                        scope: "生效范围：仅本目录下一层的未跟踪文件和文件夹，不继承到更深层目录。",
                        exists: settings?.ignore != nil)
                    propertyEditor("svn:global-ignores", value: $globalIgnores,
                        scope: "生效范围：本目录内及所有子目录中的未跟踪文件和文件夹，子目录自动继承。",
                        exists: settings?.globalIgnores != nil)
                    Text("保存为本地目录属性变更，检查并提交相应目录后才同步到服务器。清空并保存会移除本目录的对应属性，继承规则和用户全局规则仍有效。")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    inheritedRules
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if loading { ProgressView("正在读取目录属性和继承规则…").controlSize(.small) }
            if model.busy { ProgressView("正在保存并刷新…").controlSize(.small) }
            if !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : .secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新读取") { requestLoad(directory) }.disabled(unavailable)
                Spacer()
                Button("完成", action: requestClose).keyboardShortcut(.cancelAction).disabled(unavailable)
                Button("保存目录属性") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(unavailable || settings == nil || !changed || requiresReload)
            }
        }.padding(24).frame(width: 780, height: 780)
            .interactiveDismissDisabled(changed || unavailable)
            .task { await load(directory) }
            .confirmationDialog("放弃尚未保存的编辑？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(closing ? "放弃编辑并关闭" : "放弃编辑并重新读取", role: .destructive) {
                    if closing { dismiss() }
                    else if let target = pendingDirectory { Task { await load(target) } }
                }
                Button("继续编辑", role: .cancel) { pendingDirectory = nil; closing = false }
            } message: { Text("尚未保存的规则会被丢弃，已经保存的目录属性不会撤销。") }
    }

    private func propertyEditor(_ name: String, value: Binding<String>, scope: String, exists: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(name).font(.system(.headline, design: .monospaced))
                if settings != nil, !exists { Text("本目录未设置").font(.caption).foregroundStyle(.secondary) }
            }
            Text(scope).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: value).font(.system(size: 12, design: .monospaced))
                .frame(height: 110).border(Color.secondary.opacity(0.25))
                .accessibilityLabel(name + " 目录忽略规则")
                .disabled(unavailable || settings == nil)
        }
    }

    @ViewBuilder
    private var inheritedRules: some View {
        Text("继承的 svn:global-ignores").font(.headline)
        if let settings {
            if settings.inherited.isEmpty {
                Text("没有继承的目录忽略规则。上级目录的 svn:ignore 不会在此目录继承生效。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("以下祖先目录的规则会叠加生效，修改时请到来源目录编辑。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(settings.inherited.enumerated()), id: \.offset) { _, value in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("来源：" + SVNLocation.display(value.source))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("生效范围：来源目录内及其全部子目录（包含当前目录）。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(value.value.isEmpty ? "（空规则）" : value.value)
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                        if let source = editableSource(value.source, settings: settings) {
                            Button("编辑来源目录…") { requestLoad(source) }.disabled(unavailable)
                        } else {
                            Text("此来源尚未签出，当前只读；签出来源目录后可编辑并提交。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    private func editableSource(_ source: String, settings: SVNDirectoryIgnoreSettings) -> URL? {
        guard source.hasPrefix("/") else { return nil }
        let value = URL(fileURLWithPath: source).standardizedFileURL
        let root = settings.workingCopyRoot.standardizedFileURL.path
        return value.path == root || value.path.hasPrefix(root + "/") ? value : nil
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择要编辑忽略属性的版本化目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = directory
        panel.prompt = "选择目录"
        if panel.runModal() == .OK, let target = panel.url { requestLoad(target) }
    }

    private func requestLoad(_ target: URL) {
        guard !unavailable else { return }
        if changed {
            closing = false
            pendingDirectory = target
            confirmDiscard = true
        } else { Task { await load(target) } }
    }

    private func requestClose() {
        guard !unavailable else { return }
        if changed { closing = true; confirmDiscard = true }
        else { dismiss() }
    }

    @MainActor
    private func load(_ target: URL) async {
        guard !unavailable else { return }
        loading = true
        directory = target
        settings = nil
        ignore = ""
        globalIgnores = ""
        feedback = ""
        defer { loading = false }
        do {
            let value = try await model.readDirectoryIgnoreSettings(at: target)
            guard !Task.isCancelled else { return }
            apply(value)
            requiresReload = false
            failed = false
        } catch { failed = true; feedback = error.localizedDescription }
    }

    private func apply(_ value: SVNDirectoryIgnoreSettings) {
        settings = value
        directory = value.directory
        ignore = value.ignore ?? ""
        globalIgnores = value.globalIgnores ?? ""
    }

    @MainActor
    private func save() async {
        guard let settings, !unavailable, !requiresReload else { return }
        feedback = ""
        do {
            let result = try await model.saveDirectoryIgnoreSettings(using: settings, ignore: ignore, globalIgnores: globalIgnores)
            apply(result.settings)
            failed = result.refreshWarning != nil
            feedback = result.refreshWarning ?? (result.changed ? "已保存在本地并读回确认，请检查后提交相应目录。" : "目录属性未变化。")
            if let folder = result.backupDirectory { feedback += "\n原属性备份：" + folder.path }
        } catch {
            requiresReload = true
            failed = true
            feedback = error.localizedDescription + "\n请重新读取目录属性，核对后再编辑。"
        }
    }
}
