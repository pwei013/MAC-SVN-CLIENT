import SwiftUI
import SVNCore

struct IncomingUpdatesView: View {
    let session: IncomingSession
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SVNIncomingUpdate] = []
    @State private var selection: String?
    @State private var query = ""
    @State private var onlyOverlapping = false
    @State private var loading = false
    @State private var error: String?
    @State private var comparison: FileDiffPresentation?
    @State private var comparisonTitle = ""
    @State private var readTask: Task<Void, Never>?
    @State private var filterTask: Task<Void, Never>?

    init(session: IncomingSession, appModel: AppModel) {
        self.session = session
        self.appModel = appModel
        _rows = State(initialValue: session.report.entries)
    }

    private var selected: SVNIncomingUpdate? { rows.first { $0.path == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("云端更新检查", systemImage: "arrow.down.circle").font(.title2.bold())
                Spacer()
                if loading { ProgressView().controlSize(.small); Button("取消读取") { readTask?.cancel() } }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(session.directory.path).font(.callout).lineLimit(1).textSelection(.enabled)
            Text("已检查云端 r\(session.report.revision) · \(session.report.entries.count) 项可更新。检查没有更新或覆盖本地文件。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Toggle("仅显示本地也有修改的项目", isOn: $onlyOverlapping).toggleStyle(.checkbox)
                Spacer()
                TextField("筛选路径", text: $query).textFieldStyle(.roundedBorder).frame(width: 230)
            }.font(.callout)
            Table(rows, selection: $selection) {
                TableColumn("云端状态") { Text($0.remoteLabel) }.width(105)
                TableColumn("本地状态") { item in
                    Text(item.hasLocalChanges ? "本地也有修改" : "无本地修改").foregroundStyle(item.hasLocalChanges ? Color.orange : Color.secondary)
                }.width(120)
                TableColumn("文件路径") { item in
                    HStack { FileTypeIcon(path: item.path, kind: item.nodeKind); Text(item.path).lineLimit(1) }.help(item.path)
                }.width(min: 260, ideal: 540)
            }.frame(minHeight: 360)
                .overlay {
                    if rows.isEmpty {
                        Text(session.report.entries.isEmpty ? "当前范围没有待更新项目" : "没有匹配的项目").foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            Text("本地与云端都修改过，表示需要检查；是否冲突须以更新合并结果为准。关闭本窗口后可使用“更新”。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("比较固定在本次检查的版本，不会自动读取更新后的 HEAD。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看差异", action: compare).disabled(loading || !canCompare)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).lineLimit(4).textSelection(.enabled) }
        }.padding(20).frame(minWidth: 1_050, minHeight: 650)
        .task { filter() }
        .onChange(of: query) { _, _ in filter() }
        .onChange(of: onlyOverlapping) { _, _ in filter() }
        .onDisappear { readTask?.cancel(); filterTask?.cancel() }
        .sheet(item: $comparison) { value in
            DiffView(title: comparisonTitle, text: "", context: "本地与本次云端检查版本的只读比较。", fileDiff: value)
        }
    }

    private func filter() {
        filterTask?.cancel()
        let term = query, overlap = onlyOverlapping, entries = session.report.entries
        filterTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                let worker = Task.detached(priority: .userInitiated) {
                    var result: [SVNIncomingUpdate] = []
                    for entry in entries {
                        try Task.checkCancellation()
                        if (!overlap || entry.hasLocalChanges) && (term.isEmpty || entry.path.localizedCaseInsensitiveContains(term)) { result.append(entry) }
                    }
                    return result
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                rows = result
                if !rows.contains(where: { $0.path == selection }) { selection = nil }
            } catch { }
        }
    }

    private func compare() {
        guard !loading, canCompare, let item = selected else { return }
        loading = true; error = nil
        readTask = Task {
            defer { loading = false; readTask = nil }
            do {
                let target = try await session.client.prepareRemoteFileDiff(at: session.directory, path: item.path)
                let files = try await session.client.fileComparison(target, revision: .revision(session.report.revision), snapshotPath: true)
                let value = try await appModel.prepareFilePresentation(files, path: item.path)
                try Task.checkCancellation()
                comparisonTitle = item.path; comparison = value
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private var canCompare: Bool {
        guard let item = selected else { return false }
        return [.file, .symbolicLink].contains(item.nodeKind) && item.remoteItem != "deleted"
    }
}
