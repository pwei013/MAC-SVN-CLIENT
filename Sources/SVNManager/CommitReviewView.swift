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
                Text("以下 \(changes.count) 项将提交到服务器：").font(.headline)
                List(changes) { change in
                    HStack(spacing: 8) {
                        Text(change.label).foregroundStyle(statusColor(change)).fixedSize()
                        FileTypeIcon(path: change.path, kind: change.nodeKind)
                        Text(change.path).font(.system(.callout, design: .monospaced))
                            .lineLimit(2).truncationMode(.middle).help(change.path)
                    }
                }.frame(minHeight: 0, maxHeight: .infinity)
                    .accessibilityLabel("本次提交文件清单")
                Text("提交说明").font(.headline)
                ScrollView {
                    Text(message).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.frame(height: min(96, size.height * 0.15))
                    .accessibilityLabel("本次提交说明")
            }.padding(.horizontal, 24).padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("只提交勾选项。新建目录的父路径也需勾选；未勾选的子文件会保留在本地。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("检查云端更新…", action: checkUpdates).disabled(isBusy)
                    Spacer()
                    Button("返回检查", action: goBack).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("commit-review-back")
                    Button("提交到服务器", action: commit).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(isBusy)
                        .accessibilityIdentifier("commit-review-submit")
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: size.width, height: size.height)
    }
}
