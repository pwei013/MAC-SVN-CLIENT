import AppKit
import SwiftUI
import SVNCore

struct FileComparisonContent: View {
    let presentation: FileDiffPresentation
    let findRequest: Int
    @State private var showsSearch = false
    @State private var query = ""
    @State private var matches: [Int] = []
    @State private var matchIndex = 0
    @State private var changeIndex = -1
    @State private var focusedRow: Int?
    @State private var jumpID = 0
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var changesOnly = false
    @State private var syntaxColors = true
    @State private var rowMap: SVNDiffRowMap?
    @State private var mappingID = UUID()
    @State private var preparingMap = false
    @State private var mapTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                legend("新增", count: presentation.lines.addedCount, color: .green, mark: "+")
                legend("删除", count: presentation.lines.deletedCount, color: .red, mark: "−")
                legend("修改", count: presentation.lines.modifiedCount, color: .orange, mark: "↔")
                Spacer()
                Button("上一处差异") { moveChange(-1) }.disabled(presentation.changeStarts.isEmpty)
                Button("下一处差异") { moveChange(1) }.disabled(presentation.changeStarts.isEmpty)
                if !presentation.changeStarts.isEmpty {
                    Text("\(max(0, changeIndex + 1))/\(presentation.changeStarts.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }.font(.callout)
            HStack(spacing: 16) {
                Toggle("仅差异与上下文", isOn: $changesOnly).toggleStyle(.checkbox).disabled(preparingMap)
                    .help("保留变化前后各 3 行，原始行号不变；查找隐藏内容时自动展开。")
                Toggle("代码着色", isOn: $syntaxColors).toggleStyle(.checkbox).disabled(!supportsSyntax)
                    .help("只对可见行进行后台着色；不改变差异颜色或文件内容。")
                if preparingMap { ProgressView().controlSize(.small); Text("正在整理上下文…").foregroundStyle(.secondary) }
                else if let rowMap, rowMap.hiddenCount > 0 {
                    Text("已折叠 \(rowMap.hiddenCount) 行，分隔线表示省略内容").foregroundStyle(.secondary)
                } else if changesOnly { Text("没有可折叠的变化上下文").foregroundStyle(.secondary) }
                Spacer()
            }.font(.caption)
            if showsSearch { searchBar }
            HStack(spacing: 0) {
                paneHeader(presentation.files.localLabel, document: presentation.files.local, copy: presentation.files.local.text)
                Divider()
                paneHeader(presentation.files.remoteLabel, document: presentation.files.remote, copy: presentation.files.remote.text)
            }.frame(height: 56).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            GeometryReader { geometry in
                SideBySideDiffView(presentation: presentation, rowMap: rowMap, mappingID: mappingID,
                                   syntaxColors: syntaxColors && supportsSyntax, focusedRow: focusedRow, jumpID: jumpID)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }.frame(minHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.2)))
            if let notice = presentation.files.notice { note(notice) }
            if let notice = presentation.lines.notice { note(notice) }
            Text("颜色表示左侧相对右侧的增删改，深色块强调变化字符。保留原始行号，可按 ⌘C 复制选中行，左右滚动同步。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: findRequest) { _, _ in showsSearch = true; searchFocused = true }
        .onChange(of: query) { _, _ in matches = []; matchIndex = 0; searchTask?.cancel(); searching = false }
        .onChange(of: changesOnly) { _, _ in prepareMap() }
        .onChange(of: presentation.id) { _, _ in
            searchTask?.cancel(); mapTask?.cancel(); searching = false; preparingMap = false
            matches = []; matchIndex = 0; changeIndex = -1; focusedRow = nil
            rowMap = nil; mappingID = UUID()
            if changesOnly { prepareMap() }
        }
        .onDisappear { searchTask?.cancel(); mapTask?.cancel() }
    }

    private var supportsSyntax: Bool {
        ["cs", "swift", "js", "jsx", "ts", "tsx", "json", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "py",
         "xml", "html", "htm", "xaml", "csproj", "vbproj", "props", "targets", "config", "plist", "svg"].contains(presentation.language)
    }

    private func legend(_ text: String, count: Int, color: Color, mark: String) -> some View {
        HStack(spacing: 5) {
            Text(mark).font(.system(.callout, design: .monospaced).bold()).foregroundStyle(color)
            Text("\(text) \(count) 行").monospacedDigit()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paneHeader(_ title: String, document: SVNTextFileDocument, copy: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text("\(document.encoding) · \(document.lineEnding)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("复制全文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            }.font(.caption)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("查找两侧内容", text: $query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).onSubmit { search() }
                .onExitCommand { showsSearch = false; searchTask?.cancel() }
            Button("查找", action: search).disabled(query.isEmpty || searching)
            Button("上一个") { moveMatch(-1) }.disabled(matches.isEmpty)
            Button("下一个") { moveMatch(1) }.disabled(matches.isEmpty)
            if searching { ProgressView().controlSize(.small) }
            else { Text(matches.isEmpty ? "0 行" : "\(matchIndex + 1)/\(matches.count) 行").font(.caption).monospacedDigit() }
            Button("收起") { showsSearch = false; searchTask?.cancel() }
        }
    }

    private func jump(_ row: Int, revealSearchResult: Bool = false) {
        let hidden = rowMap.map { $0.displayIndex(forSource: row) == nil } ?? false
        if (revealSearchResult && (changesOnly || preparingMap)) || hidden {
            mapTask?.cancel(); preparingMap = false; changesOnly = false
            self.rowMap = nil; mappingID = UUID()
        }
        focusedRow = row; jumpID += 1
    }

    private func prepareMap() {
        mapTask?.cancel()
        guard changesOnly else { preparingMap = false; rowMap = nil; mappingID = UUID(); return }
        preparingMap = true
        let rows = presentation.lines.rows, presentationID = presentation.id
        mapTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try SVNDiffRowMap.make(rows: rows, changesOnly: true) }
            do {
                let map = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, changesOnly, presentation.id == presentationID else { return }
                rowMap = map; mappingID = UUID(); preparingMap = false
                if let focusedRow, map.displayIndex(forSource: focusedRow) == nil { self.focusedRow = nil }
            } catch { if !Task.isCancelled { preparingMap = false } }
        }
    }

    private func moveChange(_ direction: Int) {
        let count = presentation.changeStarts.count
        guard count > 0 else { return }
        changeIndex = changeIndex < 0 ? (direction > 0 ? 0 : count - 1) : (changeIndex + direction + count) % count
        jump(presentation.changeStarts[changeIndex])
    }

    private func moveMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + direction + matches.count) % matches.count
        jump(matches[matchIndex], revealSearchResult: true)
    }

    private func search() {
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        let term = query
        let rows = presentation.lines.rows
        searching = true
        searchTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                var found: [Int] = []
                for (index, row) in rows.enumerated() {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    if row.localText?.localizedCaseInsensitiveContains(term) == true || row.remoteText?.localizedCaseInsensitiveContains(term) == true {
                        found.append(index)
                    }
                }
                return found
            }
            do {
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, query == term else { return }
                matches = found
                matchIndex = 0
                searching = false
                if let first = found.first { jump(first, revealSearchResult: true) }
            } catch { if !Task.isCancelled { searching = false } }
        }
    }
}
