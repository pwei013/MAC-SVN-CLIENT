import SwiftUI

struct WorkingCopyToolbar: View {
    @ObservedObject var model: AppModel
    let add: ([String]) -> Void
    let deleteMissing: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 14) {
                workingCopyActions
                Divider().frame(height: 42)
                fileActions
                Spacer(minLength: 12)
                Divider().frame(height: 32)
                utilityActions
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    workingCopyActions
                    fileActions
                }
                Spacer(minLength: 8)
                utilityActions.padding(.top, 18)
            }
        }
        .controlSize(.regular).font(.callout)
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(.quaternary.opacity(0.18))
        .disabled(model.busy)
    }

    private var workingCopyActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            groupLabel("工作副本")
            HStack(spacing: 8) {
                Button(action: model.refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                Button(action: model.update) { Label("更新", systemImage: "arrow.down.circle") }
                Button(action: model.checkIncomingUpdates) { Label("检查云端更新", systemImage: "icloud") }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var fileActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            groupLabel("所选文件")
            HStack(spacing: 8) {
                Button(action: model.previewDiff) { Label("查看差异", systemImage: "doc.text.magnifyingglass") }
                    .disabled(model.changeSelection == nil)
                    .help("比较所选文件与签出基线（BASE）")
                Button { add(model.addablePaths) } label: { Label("Add", systemImage: "plus.circle") }
                    .disabled(model.addablePaths.isEmpty)
                    .help("将勾选或选中的未跟踪项添加到版本控制")
                Button { model.openConflict() } label: { Label("处理冲突", systemImage: "exclamationmark.triangle") }
                    .disabled(!model.hasConflict(model.changeSelection ?? ""))
                Menu("更多") {
                    Button("Add 到版本控制…") { add(model.addablePaths) }.disabled(model.addablePaths.isEmpty)
                    Button("撤销 Add…") { model.prepareLocalAction(.undoAdd, paths: model.localActionPaths(.undoAdd)) }
                        .disabled(model.localActionPaths(.undoAdd).isEmpty)
                    Button("删除选中项目…") { model.prepareLocalAction(.delete, paths: model.localActionPaths(.delete)) }
                        .disabled(model.localActionPaths(.delete).isEmpty)
                    Button("选择版本化文件或目录删除…", action: model.chooseVersionedDeletion)
                    Divider()
                    Button("将勾选的缺失路径标记为删除…", action: deleteMissing)
                        .disabled(!model.checkedChanges.contains { $0.item == "missing" })
                }.fixedSize().accessibilityLabel("更多文件操作")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var utilityActions: some View {
        HStack(spacing: 8) {
            Button { model.openWorkingHistory() } label: { Label("提交历史", systemImage: "clock") }
            Menu {
                Button("仓库权限…") {
                    if let url = model.workingInfo?.url { model.permissionTarget = .init(url: url) }
                }.disabled(model.workingInfo == nil)
                Button("目录忽略属性…") { model.editDirectoryIgnores() }
                Divider()
                Button("SVN 设置…") { model.showSettings = true }
            } label: {
                Image(systemName: "gearshape")
            }.fixedSize().help("工作副本设置").accessibilityLabel("工作副本设置")
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }
}
