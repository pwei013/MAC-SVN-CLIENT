import AppKit
import SwiftUI
import SVNCore

struct LocalActionReviewView: View {
    let plan: SVNLocalActionPlan
    let isBusy: Bool
    let cancel: () -> Void
    let confirm: (Bool) -> Void
    @State private var keepLocal = true

    private var undoing: Bool { plan.action == .undoAdd }
    private var dialogSize: CGSize {
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        var size = CommitReviewView.fittedSize(in: (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1_000, height: 800))
        if let window {
            size.width = min(size.width, max(320, window.contentLayoutRect.width - 48))
            size.height = min(size.height, max(280, window.contentLayoutRect.height - 60))
        }
        return size
    }
    var body: some View {
        let size = dialogSize
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(undoing ? "撤销 Add，保留本地文件" : "确认删除版本化项目").font(.title2.bold())
                Text(plan.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text("已选 \(plan.targets.count) 项，涉及 \(plan.items.count) 个版本化文件和目录。目录操作包含清单中的子项。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }.padding(20).fixedSize(horizontal: false, vertical: true)
            Divider()
            List(plan.items) { item in
                HStack(spacing: 8) {
                    FileTypeIcon(path: item.path, kind: item.kind)
                    Text(item.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }.frame(minHeight: 0, maxHeight: .infinity).accessibilityLabel("本次操作影响清单")
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if undoing {
                    Text("仅取消清单中项目的新增标记，文件内容和其他修改保持不变。刷新后可按需加入忽略规则。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("保留本地文件，仅标记从版本控制删除", isOn: $keepLocal).toggleStyle(.checkbox)
                    Text(keepLocal ? "文件仍保存在本机。勾选待删除项并提交后，服务器才会删除对应版本。" :
                        "本地版本化文件将从磁盘删除，提交后服务器才会删除。存在本地修改或未跟踪文件时停止，不强制删除。")
                        .font(.caption).foregroundStyle(keepLocal ? Color.secondary : .orange).fixedSize(horizontal: false, vertical: true)
                    if plan.modifiedCount > 0 { Text("清单中有 \(plan.modifiedCount) 项本地修改，建议保留本地文件。").font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Spacer()
                    Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                    Button(undoing ? "撤销 Add" : "标记为待删除") { confirm(keepLocal) }
                        .buttonStyle(.borderedProminent).tint(undoing ? .indigo : .red)
                        .disabled(isBusy).keyboardShortcut(.defaultAction)
                }
            }.padding(20).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: size.width, height: size.height)
    }
}
