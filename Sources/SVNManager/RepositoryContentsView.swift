import SwiftUI
import SVNCore

/// Row selection stays local: changing the highlight must not invalidate the app model,
/// sidebar, working-copy panel, and sheet contents.
struct RepositoryContentsView: View {
    let location: String
    let entries: [RepositoryEntry]
    let busy: Bool
    let searchQuery: String?
    let onOpen: (RepositoryEntry) -> Void
    let onReveal: (RepositoryEntry) -> Void
    let onCheckout: (RepositoryEntry?) -> Void
    let onHistory: (RepositoryEntry?) -> Void
    @State private var selection: String?
    @State private var sortOrder = RepositoryEntry.defaultSortOrder
    @State private var rows: [RepositoryEntry] = []
    @State private var sorting: Task<Void, Never>?

    private var selectedEntry: RepositoryEntry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(searchQuery == nil ? "名称" : "相对路径", value: \.name, comparator: .localizedStandard) { entry in
                    HStack(spacing: 8) {
                        FileTypeIcon(path: entry.name, kind: entry.isDirectory ? .directory : .file)
                        Text(entry.name).lineLimit(1).truncationMode(.middle).help(entry.name)
                    }
                }.width(min: 180, ideal: 300)
                TableColumn("版本", value: \.revisionNumber) { Text($0.revision.isEmpty ? "—" : "r\($0.revision)").monospacedDigit() }.width(75)
                TableColumn("最后提交人", value: \.author).width(min: 90, ideal: 120)
                TableColumn("最后上传时间", value: \.lastCommitTimestamp) { entry in
                    if let date = entry.lastCommitDate {
                        Text(date, format: Date.FormatStyle(date: .numeric, time: .standard).locale(Locale(identifier: "zh_CN")))
                            .monospacedDigit()
                            .help("SVN 记录的该条目最后提交时间，按本机时区显示")
                    } else { Text("—").foregroundStyle(.secondary) }
                }.width(min: 160, ideal: 180)
                TableColumn("大小", value: \.size) {
                    Text($0.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))
                }.width(90)
            }
            // Let the selectable container distinguish single selection from double activation.
            // A per-cell TapGesture competes with the native table selection recognizers.
            .contextMenu(forSelectionType: String.self) { ids in
                if let entry = entries.first(where: { ids.contains($0.id) }) {
                    if entry.isDirectory { Button("打开目录") { onOpen(entry) }.disabled(busy) }
                    else if searchQuery != nil { Button("打开所在目录") { onReveal(entry) }.disabled(busy) }
                    Button("提交历史") { onHistory(entry) }.disabled(busy)
                }
            } primaryAction: { ids in
                if !busy, let entry = entries.first(where: { ids.contains($0.id) }) {
                    if entry.isDirectory { onOpen(entry) }
                    else if searchQuery != nil { onReveal(entry) }
                }
            }
            .overlay {
                if searchQuery != nil, entries.isEmpty, !busy {
                    VStack(spacing: 8) {
                        Label("没有匹配结果", systemImage: "magnifyingglass").font(.headline)
                        Text("换个关键词，或返回当前目录。").font(.caption).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                }
            }

            HStack {
                Button(searchQuery != nil && selectedEntry?.isDirectory == false ? "打开所在目录" : "打开所选目录") {
                    if let entry = selectedEntry {
                        if entry.isDirectory { onOpen(entry) } else { onReveal(entry) }
                    }
                }.disabled(busy || selectedEntry == nil || (searchQuery == nil && selectedEntry?.isDirectory != true))
                Text(searchQuery == nil ? "双击目录可进入" : "双击目录进入，双击文件定位").font(.caption).foregroundStyle(.secondary)
                Button("提交历史") { onHistory(selectedEntry) }.disabled(busy)
                Spacer()
                Button { onCheckout(selectedEntry?.isDirectory == true ? selectedEntry : nil) } label: {
                    Label("签出", systemImage: "arrow.down.to.line")
                }.buttonStyle(.borderedProminent).disabled(busy || (searchQuery != nil && selectedEntry?.isDirectory != true))
            }.padding(20)
        }
        .onAppear { updateRows() }
        .onChange(of: entries) { _, _ in updateRows() }
        .onChange(of: sortOrder) { _, _ in updateRows() }
        .onChange(of: location) { _, _ in selection = nil }
        .onChange(of: searchQuery) { _, _ in selection = nil }
        .onDisappear { sorting?.cancel() }
    }

    private func updateRows() {
        sorting?.cancel()
        let values = entries, order = sortOrder
        sorting = Task {
            let worker = Task.detached(priority: .userInitiated) { RepositoryEntry.sorted(values, using: order) }
            let sorted = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            rows = sorted
            if let selection, !values.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }
}
