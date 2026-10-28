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
    var review: SVNCommitReview? = nil
    var isReading = false
    var readError: String? = nil
    var reload: () -> Void = {}
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
        let blockedCount = changes.filter { !$0.canSubmitWithAutomaticAdd }.count
        let automaticAddCount = changes.filter { $0.item == "unversioned" && $0.canSubmitWithAutomaticAdd }.count
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let entries = review?.entries ?? changes
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
                if let review {
                    HStack {
                        Text("共 \(review.fileCount) 个文件 · \(review.directoryCount) 个目录").font(.headline)
                            .accessibilityIdentifier("commit-review-total")
                        Spacer()
                        Button("重新读取", action: reload).disabled(isBusy || isReading)
                    }
                    Text("已展开未跟踪文件夹，排除 SVN 忽略项；下方为本次实际提交清单。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if isReading {
                    HStack { ProgressView().controlSize(.small); Text("正在读取实际提交文件清单…") }
                } else if let readError {
                    Text(readError).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新读取", action: reload).disabled(isBusy)
                } else {
                    Text("已勾选 \(changes.count) 项，其中 \(blockedCount) 项暂不可提交：").font(.headline)
                }
                if automaticAddCount > 0 {
                    Text("确认后先自动 Add 清单中的未跟踪文件和目录，再与其他勾选项一起提交。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if blockedCount > 0 {
                    HStack {
                        Text("请先处理下列原因，或取消这些项目的勾选。")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("取消不可提交项勾选（\(blockedCount)）", action: excludeUncommittable)
                            .disabled(isBusy)
                    }
                }
                List(entries) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(change.label).foregroundStyle(statusColor(change)).fixedSize()
                            FileTypeIcon(path: change.path, kind: change.nodeKind)
                            Text(change.path).font(.system(.callout, design: .monospaced))
                                .lineLimit(2).truncationMode(.middle).help(change.path)
                        }
                        if !change.canSubmitWithAutomaticAdd, let reason = change.commitBlockReason {
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
                Text("必要的新父目录已计入清单，文件数不含目录。提交前再次核对，清单变化时停止并要求重新检查。")
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
                    Button(automaticAddCount > 0 ? "Add 并提交到服务器" : "提交到服务器", action: commit).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBusy || isReading || review == nil || changes.isEmpty || blockedCount > 0 || !hasMessage)
                        .accessibilityIdentifier("commit-review-submit")
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: size.width, height: size.height)
    }
}
