import SwiftUI

struct RecentWorkingCopiesView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    private var matchingPaths: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = model.recentWorkingCopies
        return query.isEmpty ? paths : paths.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        if !model.recentWorkingCopies.isEmpty || !search.isEmpty {
            let paths = matchingPaths
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("最近工作副本").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(paths.count) / \(model.recentWorkingCopies.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.top, 18)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索名称或路径", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索最近工作副本")
                        .accessibilityIdentifier("recent-working-copy-search")
                        .onSubmit {
                            guard !model.busy, paths.count == 1 else { return }
                            model.openWorkingCopy(URL(fileURLWithPath: paths[0]))
                        }
                        .onExitCommand { search = "" }
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("清除最近工作副本搜索")
                            .help("清除搜索，显示所有最近工作副本")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .help("按工作副本名称或完整路径即时筛选；只有一个结果时可按回车打开，按 Esc 清除搜索")
                if paths.isEmpty {
                    Text("没有匹配的工作副本").font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(paths, id: \.self) { path in
                    RecentLocationRow(pinned: model.isWorkingCopyPinned(path),
                        isSelected: model.screen == .workingCopy && model.workingDirectory?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path,
                        isBusy: model.busy,
                        name: URL(fileURLWithPath: path).lastPathComponent, detail: path,
                        open: { model.openWorkingCopy(URL(fileURLWithPath: path)) },
                        togglePin: { model.toggleWorkingCopyPin(path) },
                        remove: { model.removeRecentWorkingCopy(path) }) {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                }
            }
        }
    }
}
