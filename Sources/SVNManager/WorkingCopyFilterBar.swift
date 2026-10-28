import SwiftUI
import SVNCore

extension AppModel {
    func scheduleChangeFiltering(debounce: Bool = false) {
        guard !applyingProjectState else { return }
        changeFilterTask?.cancel()
        let request = UUID()
        changeFilterID = request
        let values = changes, query = changeSearch, status = changeStatusFilter, kind = changeKindFilter
        isFilteringChanges = true
        changeFilterTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(120)) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try WorkingCopyFilterResult.evaluate(values, query: query, status: status, kind: kind)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.changeFilterID == request else { return }
                self.changeFilterResult = result
                self.isFilteringChanges = false
                self.changeFilterTask = nil
            } catch {
                if let self, self.changeFilterID == request { self.isFilteringChanges = false; self.changeFilterTask = nil }
            }
        }
    }

    var hasChangeFilters: Bool { changeStatusFilter != .all || changeKindFilter != .all || !changeSearch.isEmpty }
    var hiddenCheckedCount: Int {
        let visible = changeFilterResult.visiblePaths
        return checkedPaths.lazy.filter { !visible.contains($0) }.count
    }
    func clearChangeFilters() { changeSearch = ""; changeStatusFilter = .all; changeKindFilter = .all }
    func checkAllVisibleChanges() {
        guard !busy, !isFilteringChanges else { return }
        checkedPaths.formUnion(changeFilterResult.checkablePaths)
    }
    func uncheckVisibleChanges() {
        guard !busy, !isFilteringChanges else { return }
        checkedPaths.subtract(changeFilterResult.visiblePaths)
    }
    func checkVisibleCommittableChanges() {
        guard !busy, !isFilteringChanges else { return }
        checkedPaths.formUnion(filteredChanges.filter(\.canSubmitWithAutomaticAdd).map(\.path))
    }
}

struct WorkingCopyFilterBar: View {
    @ObservedObject var model: AppModel
    private var filters: [WorkingCopyStatusFilter] {
        WorkingCopyStatusFilter.allCases.filter { $0 != .ignored || model.showIgnoredFiles }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchField
                    secondaryFilters
                    Spacer(minLength: 8)
                    resetFilters
                }
                VStack(alignment: .leading, spacing: 9) {
                    searchField
                    HStack(spacing: 12) {
                        secondaryFilters
                        Spacer(minLength: 8)
                        resetFilters
                    }
                }
            }
            StatusChipLayout {
                ForEach(filters) { status in
                    let active = model.changeStatusFilter == status
                    let count = model.changeFilterResult.counts[status, default: 0]
                    Button { model.changeStatusFilter = status } label: {
                        Text("\(status.title) \(count)").monospacedDigit().font(.caption.weight(active ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(active ? Color.indigo : Color.primary)
                            .background(active ? Color.indigo.opacity(0.13) : Color.secondary.opacity(0.07), in: Capsule())
                            .overlay(Capsule().stroke(active ? Color.indigo.opacity(0.5) : Color.clear))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("状态筛选：\(status.title)，\(count) 项")
                        .accessibilityValue(active ? "已选中" : "未选中")
                        .help("仅显示\(status.title)项目，保留原有提交勾选")
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .background(.quaternary.opacity(0.12)).disabled(model.busy)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索文件路径", text: $model.changeSearch).textFieldStyle(.plain)
                .accessibilityLabel("搜索文件路径")
        }.font(.callout).padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.22)))
            .frame(minWidth: 170, idealWidth: 260, maxWidth: 360).layoutPriority(1)
    }

    private var secondaryFilters: some View {
        HStack(spacing: 12) {
            Picker("文件类型", selection: $model.changeKindFilter) {
                ForEach(WorkingCopyKindFilter.allCases) { kind in Text(kind.title).tag(kind) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 116)
                .help("按文件或文件夹筛选")
            Toggle("显示已忽略文件", isOn: Binding(get: { model.showIgnoredFiles }, set: model.setShowIgnoredFiles))
                .toggleStyle(.checkbox).fixedSize()
                .help("显示 SVN 忽略的文件和文件夹；忽略项不能直接 Add 或提交")
        }.font(.callout).fixedSize(horizontal: true, vertical: false)
    }

    private var resetFilters: some View {
        Button("重置筛选", action: model.clearChangeFilters)
            .buttonStyle(.plain).font(.callout).fixedSize()
            .foregroundStyle(model.hasChangeFilters ? Color.indigo : Color.secondary)
            .disabled(!model.hasChangeFilters)
            .help("重置路径、状态和类型，保留原有文件勾选")
    }
}

/// Native layout wraps a small fixed set of shortcuts at narrow window widths;
/// no horizontal scrolling or per-file view is introduced by the filter bar.
private struct StatusChipLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arranged(width: proposal.width ?? 800, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arranged(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading, proposal: .unspecified)
        }
    }
    private func arranged(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += height + 6; height = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + 6; height = max(height, size.height)
        }
        return (CGSize(width: width, height: y + height), points)
    }
}
