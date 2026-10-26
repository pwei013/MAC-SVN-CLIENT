import SwiftUI
import SVNCore

func historyPageCost(_ values: [SVNHistoryEntry]) -> Int {
    values.reduce(0) { sum, entry in
        sum + entry.message.utf8.count + entry.paths.reduce(0) { $0 + $1.path.utf8.count + ($1.copyFromPath?.utf8.count ?? 0) + 128 } + 256
    }
}

private struct HistoryRow: Identifiable, Sendable {
    var id: Int64 { entry.revision }
    let entry: SVNHistoryEntry
    let date: String
    let summary: String
}

@MainActor
private final class HistoryPanelModel: ObservableObject {
    let session: HistorySession
    @Published var rows: [HistoryRow] = []
    @Published var entries: [SVNHistoryEntry]
    @Published var hasMore: Bool
    @Published var loading = false
    @Published var filtering = false
    @Published var error: String?
    @Published var comparison: FileDiffPresentation?
    @Published var comparisonTitle = ""
    var cursor: Int64?
    var request: Task<Void, Never>?
    var filterTask: Task<Void, Never>?
    var query = ""
    private var retainedBytes: Int

    init(_ session: HistorySession) {
        self.session = session
        entries = session.page.entries
        hasMore = session.page.hasMore
        cursor = session.page.nextBeforeRevision
        retainedBytes = session.byteCost
    }

    func filter(_ text: String) {
        query = text
        filterTask?.cancel()
        filtering = true
        let values = entries
        filterTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let worker = Task.detached(priority: .userInitiated) {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "zh_CN")
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    var result: [HistoryRow] = []
                    for entry in values {
                        try Task.checkCancellation()
                        guard text.isEmpty || entry.author.localizedCaseInsensitiveContains(text) ||
                                entry.message.localizedCaseInsensitiveContains(text) || String(entry.revision).contains(text) ||
                                entry.date.contains(text) else { continue }
                        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(entry.date)) ??
                            (try? Date.ISO8601FormatStyle().parse(entry.date))
                        result.append(HistoryRow(entry: entry, date: date.map { formatter.string(from: $0) } ?? entry.date,
                            summary: String(entry.message.split(whereSeparator: \.isNewline).first ?? "")))
                    }
                    return result
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                rows = result
                filtering = false
            } catch { if !Task.isCancelled { filtering = false } }
        }
    }

    func more() {
        guard !loading, hasMore, let cursor else { return }
        loading = true; error = nil
        request = Task {
            defer { loading = false; request = nil }
            do {
                let page = try await session.client.history(url: session.url, beforeRevision: cursor,
                    snapshotRevision: session.page.snapshotRevision)
                try Task.checkCancellation()
                let cost = await Task.detached(priority: .userInitiated) { historyPageCost(page.entries) }.value
                try Task.checkCancellation()
                guard entries.count + page.entries.count <= 2_000, retainedBytes + cost <= 32 * 1_024 * 1_024 else {
                    error = "已达到本窗口的 2,000 条或 32 MiB 缓存上限，请关闭后进入更具体的文件或目录查看历史。"
                    hasMore = false
                    return
                }
                entries.append(contentsOf: page.entries)
                retainedBytes += cost
                hasMore = page.hasMore
                self.cursor = page.nextBeforeRevision
                filter(query)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func compare(path: SVNHistoryPath, revisions: Set<Int64>, app: AppModel) {
        guard !loading, revisions.count == 2, path.kind != "dir", let old = revisions.min(), let new = revisions.max() else { return }
        loading = true; error = nil
        request = Task {
            defer { loading = false; request = nil }
            do {
                let relative = String(path.path.drop(while: { $0 == "/" }))
                let url = relative.isEmpty ? session.repositoryRoot : try SVNLocation.child(relative, of: session.repositoryRoot)
                // The newer side is left, so green additions follow chronological change.
                let files = try await session.client.historyComparison(url: url, pegRevision: new,
                    leftRevision: new, rightRevision: old)
                let value = try await app.prepareFilePresentation(files, path: path.path)
                try Task.checkCancellation()
                comparisonTitle = path.path
                comparison = value
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func cancel() { request?.cancel() }
    func close() { request?.cancel(); filterTask?.cancel() }
}

struct HistoryView: View {
    let session: HistorySession
    let appModel: AppModel
    @StateObject private var model: HistoryPanelModel
    @State private var selection = Set<Int64>()
    @State private var pathSelection: String?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(session: HistorySession, appModel: AppModel) {
        self.session = session; self.appModel = appModel
        _model = StateObject(wrappedValue: HistoryPanelModel(session))
        _selection = State(initialValue: Set(session.page.entries.first.map { [$0.revision] } ?? []))
    }

    private var entry: SVNHistoryEntry? { model.entries.first { $0.revision == selection.max() } }
    private var path: SVNHistoryPath? { entry?.paths.first { $0.path == pathSelection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("提交历史", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Spacer()
                if model.loading { ProgressView().controlSize(.small); Button("取消读取", action: model.cancel) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(SVNLocation.display(session.url)).font(.callout).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            HStack {
                Text("固定快照 r\(session.page.snapshotRevision) · 已加载 \(model.entries.count) 条")
                Spacer()
                if model.filtering { ProgressView().controlSize(.small) }
                TextField("筛选已加载记录：作者、日期、说明、版本", text: $query).textFieldStyle(.roundedBorder).frame(width: 320)
            }.font(.caption)
            Table(model.rows, selection: $selection) {
                TableColumn("版本") { Text("r\($0.entry.revision)").monospacedDigit() }.width(80)
                TableColumn("作者") { Text($0.entry.author) }.width(min: 75, ideal: 100)
                TableColumn("提交时间") { Text($0.date).monospacedDigit() }.width(165)
                TableColumn("提交说明") { Text($0.summary).lineLimit(1).help($0.summary) }.width(min: 200, ideal: 440)
            }.frame(minHeight: 180)
            HStack {
                Text("按住 ⌘ 选择两个版本，再选择下方文件进行比较。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("加载更早记录", action: model.more).disabled(!model.hasMore || model.loading)
            }
            if let entry {
                Text("r\(entry.revision) 的说明和变更文件").font(.headline)
                ScrollView { Text(entry.message.isEmpty ? "（无提交说明）" : entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 40, maxHeight: 90)
                Table(entry.paths, selection: $pathSelection) {
                    TableColumn("操作") { Text(action($0.action)) }.width(65)
                    TableColumn("文件路径") { item in
                        HStack { FileTypeIcon(path: item.path, kind: item.kind == "dir" ? .directory : .file); Text(item.path).lineLimit(1) }.help(item.path)
                    }.width(min: 260, ideal: 540)
                    TableColumn("复制来源") { item in Text(item.copyFromPath.map { "\($0) @ r\(item.copyFromRevision ?? 0)" } ?? "—").lineLimit(1) }.width(min: 140, ideal: 220)
                }.frame(minHeight: 130, maxHeight: 220)
            }
            HStack {
                Text("只读查看；版本中不存在的新增、删除路径会明确提示。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("比较选中的两个版本") {
                    if let path { model.compare(path: path, revisions: selection, app: appModel) }
                }.disabled(selection.count != 2 || path == nil || path?.kind == "dir" || model.loading)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4) }
        }.padding(20).frame(minWidth: 1_050, minHeight: 730)
        .task { model.filter("") }
        .onChange(of: query) { _, value in model.filter(value) }
        .onChange(of: selection) { _, _ in pathSelection = nil }
        .onDisappear { model.close() }
        .sheet(item: $model.comparison) { value in
            DiffView(title: model.comparisonTitle, text: "", context: "左侧较新版本，右侧较早版本；颜色表示较新版本的增删改。", fileDiff: value)
        }
    }

    private func action(_ code: String) -> String {
        switch code { case "A": return "新增"; case "D": return "删除"; case "R": return "替换"; default: return "修改" }
    }
}
