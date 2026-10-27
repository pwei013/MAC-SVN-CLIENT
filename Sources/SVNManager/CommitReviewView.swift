import AppKit
import SwiftUI
import SVNCore

struct CommitReviewView: View {
    let repositoryURL: String
    let changes: [WorkingCopyChange]
    let message: String
    let isBusy: Bool
    let statusColor: (WorkingCopyChange) -> Color
    let checkUpdates: () -> Void
    let goBack: () -> Void
    let commit: () -> Void
    let excludeUncommittable: () -> Void
    var availableSize: CGSize? = nil

    private var dialogSize: CGSize {
        if let availableSize { return Self.fittedSize(in: availableSize) }
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        let screen = window?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1_000, height: 800)
        var size = Self.fittedSize(in: available)
        if let window {
            size.width = min(size.width, max(320, window.contentLayoutRect.width - 48))
            size.height = min(size.height, max(280, window.contentLayoutRect.height - 60))
        }
        return size
    }

    static func fittedSize(in available: CGSize) -> CGSize {
        CGSize(width: min(760, max(320, available.width - 64)),
               height: min(620, max(280, available.height - 120)))
    }

    var body: some View {
        let size = dialogSize
        let blockedCount = changes.filter { !$0.canCommit }.count
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("确认提交到 SVN").font(.title2.bold()).accessibilityIdentifier("commit-review-title")
                Text(SVNLocation.display(repositoryURL)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(SVNLocation.display(repositoryURL))
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(blockedCount == 0 ? "以下 \(changes.count) 项将提交到服务器：" :
                    "已勾选 \(changes.count) 项，其中 \(blockedCount) 项暂不可提交：").font(.headline)
                if blockedCount > 0 {
                    HStack {
                        Text("请先处理下列原因，或取消这些项目的勾选。")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("取消不可提交项勾选（\(blockedCount)）", action: excludeUncommittable)
                            .disabled(isBusy)
                    }
                }
                List(changes) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(change.label).foregroundStyle(statusColor(change)).fixedSize()
                            FileTypeIcon(path: change.path, kind: change.nodeKind)
                            Text(change.path).font(.system(.callout, design: .monospaced))
                                .lineLimit(2).truncationMode(.middle).help(change.path)
                        }
                        if let reason = change.commitBlockReason {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(minHeight: 0, maxHeight: .infinity)
                    .accessibilityLabel("本次提交文件清单")
                Text("提交说明").font(.headline)
                ScrollView {
                    Text(hasMessage ? message : "尚未填写提交说明，请返回填写。")
                        .foregroundStyle(hasMessage ? Color.primary : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.frame(height: min(96, size.height * 0.15))
                    .accessibilityLabel("本次提交说明")
            }.padding(.horizontal, 24).padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("只提交勾选项。新建目录的父路径也需勾选；未勾选的子文件会保留在本地。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if changes.contains(where: { $0.item == "deleted" && $0.nodeKind == .directory }) {
                    Text("提交待删除目录会同时删除其仓库子项；本地文件是否保留取决于删除时的选择。")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("检查云端更新…", action: checkUpdates).disabled(isBusy)
                    Spacer()
                    Button("返回检查", action: goBack).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("commit-review-back")
                    Button("提交到服务器", action: commit).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBusy || changes.isEmpty || blockedCount > 0 || !hasMessage)
                        .accessibilityIdentifier("commit-review-submit")
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: size.width, height: size.height)
    }
}
