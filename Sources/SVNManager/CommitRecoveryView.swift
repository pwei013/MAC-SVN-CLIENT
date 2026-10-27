import AppKit
import SwiftUI
import SVNCore

struct CommitRecoveryView: View {
    let plan: SVNCommitRecoveryPlan
    let isBusy: Bool
    let close: () -> Void
    let execute: (SVNCommitRecoveryAction, Bool) -> Void
    @State private var action: SVNCommitRecoveryAction
    @State private var confirmedIdle = false

    init(plan: SVNCommitRecoveryPlan, isBusy: Bool, close: @escaping () -> Void,
         execute: @escaping (SVNCommitRecoveryAction, Bool) -> Void) {
        self.plan = plan; self.isBusy = isBusy; self.close = close; self.execute = execute
        _action = State(initialValue: plan.actions.first ?? .review)
    }

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
        let size = dialogSize, scope = plan.scope(for: action)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("提交处理建议").font(.title2.bold())
                Text(plan.reason).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(plan.directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }.padding(20).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(plan.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let warning = plan.inspectionWarning { Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Picker("推荐操作", selection: $action) {
                        ForEach(plan.actions) { option in
                            Text(option.title + (option == plan.actions.first ? "（推荐）" : "")).tag(option)
                        }
                    }.pickerStyle(.menu).accessibilityLabel("推荐操作")
                    Text(action.effect).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if action == .cleanup {
                        Toggle("我已确认没有其他 SVN 客户端正在操作此工作副本", isOn: $confirmedIdle)
                            .toggleStyle(.checkbox).font(.callout)
                    }
                    Text("生效范围 · \(scope.count) 项").font(.headline)
                    List(scope, id: \.self) { path in
                        Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(height: min(190, max(64, Double(scope.count) * 28 + 18)))
                        .accessibilityLabel("推荐操作生效范围")
                    DisclosureGroup("具体错误与 SVN 诊断") {
                        Text(plan.details).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.callout)
                }.padding(20)
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("仅执行您确认的操作，不会自动重新提交代码。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action.confirmationTitle) { execute(action, confirmedIdle) }
                        .buttonStyle(.borderedProminent).disabled(isBusy || (action == .cleanup && !confirmedIdle))
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(20).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(width: size.width, height: size.height)
            .onChange(of: action) { _, _ in confirmedIdle = false }
    }
}
