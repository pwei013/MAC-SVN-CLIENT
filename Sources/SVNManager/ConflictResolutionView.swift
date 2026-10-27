import AppKit
import SwiftUI
import SVNCore

struct ConflictResolutionView: View {
    let plan: SVNConflictPlan
    let presentation: FileDiffPresentation?
    let isBusy: Bool
    let requiresReload: Bool
    let close: () -> Void
    let review: (SVNConflictChoice, String, SVNMergeLineEnding) -> Void
    let resolution: SVNConflictResolution?
    let reviewError: String?
    let clearReview: () -> Void
    let apply: (SVNConflictResolution) -> Void

    @State private var choice = SVNConflictChoice.mine
    @State private var lineEnding: SVNMergeLineEnding
    @State private var showsEditor = false
    @State private var findRequest = 0
    @State private var confirmsDiscard = false
    @StateObject private var draft: ConflictMergeDraft

    init(plan: SVNConflictPlan, presentation: FileDiffPresentation?, isBusy: Bool, requiresReload: Bool = false,
         close: @escaping () -> Void,
         review: @escaping (SVNConflictChoice, String, SVNMergeLineEnding) -> Void,
         resolution: SVNConflictResolution?, reviewError: String?, clearReview: @escaping () -> Void,
         apply: @escaping (SVNConflictResolution) -> Void) {
        self.plan = plan; self.presentation = presentation; self.isBusy = isBusy; self.requiresReload = requiresReload
        self.close = close; self.review = review; self.resolution = resolution
        self.reviewError = reviewError; self.clearReview = clearReview; self.apply = apply
        _lineEnding = State(initialValue: plan.preferredLineEnding)
        _draft = StateObject(wrappedValue: ConflictMergeDraft(plan.canMerge ? plan.workingDocument?.text ?? "" : ""))
    }

    private var dialogSize: CGSize {
        let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1_280, height: 900)
        var size = CGSize(width: min(1_180, max(320, screen.width - 64)),
                          height: min(850, max(300, screen.height - 100)))
        if let window {
            size.width = min(size.width, max(320, window.contentLayoutRect.width - 48))
            size.height = min(size.height, max(300, window.contentLayoutRect.height - 60))
        }
        return size
    }

    private var canReview: Bool {
        !isBusy && !requiresReload && plan.blockingReason == nil && (choice != .manual || plan.canMerge)
    }

    var body: some View {
        let size = dialogSize
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let reason = plan.blockingReason {
                        Label("此项不能按普通文件内容冲突处理", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let notice = plan.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if plan.blockingReason == nil && presentation != nil && !plan.canMerge {
                        Text("当前工作内容较大或无法可靠解码，仅支持完整版本选择；可在外部编辑后重新读取。内置手动编辑要求各参与文件不超过 512 KiB。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if plan.blockingReason == nil { controls }
                    if let error = reviewError {
                        Text("上次检查：\n" + error).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if requiresReload {
                        Label("请关闭窗口后重新读取当前冲突，避免重复执行。此处草稿仍可复制。", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if showsEditor && plan.canMerge { mergeEditor(height: max(300, size.height - 340)) }
                    else if let presentation {
                        FileComparisonContent(presentation: presentation, findRequest: findRequest)
                            .frame(height: max(560, size.height - 300))
                    } else if plan.blockingReason == nil { binaryComparison }
                }.padding(20)
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: size.width, height: size.height)
        .interactiveDismissDisabled(isBusy || draft.isEdited)
        .onChange(of: choice) { _, value in
            clearReview()
            showsEditor = value == .manual
        }
        .onChange(of: showsEditor) { _, value in
            if value && plan.canMerge && choice != .manual { choice = .manual; clearReview() }
        }
        .onChange(of: lineEnding) { _, _ in clearReview() }
        .alert("确认解决此文件冲突？", isPresented: Binding(
            get: { resolution != nil }, set: { if !$0 { clearReview() } }), presenting: resolution) { snapshot in
                Button("返回检查", role: .cancel) { clearReview() }
                Button("确认并标记已解决") { apply(snapshot) }.disabled(isBusy || requiresReload)
            } message: { snapshot in
                Text(confirmationText(snapshot))
            }
        .confirmationDialog("放弃尚未应用的手动合并内容？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃草稿并关闭", role: .destructive, action: close)
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text(requiresReload ? "编辑区草稿将被丢弃。已执行操作的结果请关闭后刷新核对；如已生成备份，路径见错误信息。" : "磁盘文件和 SVN 冲突状态尚未改变。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("处理冲突", systemImage: "arrow.triangle.branch").font(.title2.bold())
            Text(plan.path).font(.system(.headline, design: .monospaced)).lineLimit(2).textSelection(.enabled)
            Text("云端为冲突发生时的入站版本\(plan.incomingRevision.isEmpty ? "" : " r" + plan.incomingRevision)，不会改用最新 HEAD。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("冲突处理方式", selection: $choice) {
                    ForEach(SVNConflictChoice.allCases.filter { $0 != .manual || plan.canMerge }) { option in
                        Text(option.title).tag(option)
                    }
                }.pickerStyle(.menu).frame(maxWidth: 430, alignment: .leading)
                    .disabled(isBusy || plan.blockingReason != nil)
                Spacer()
                if presentation != nil && !showsEditor {
                    Button("查找") { findRequest += 1 }.disabled(isBusy)
                }
            }
            Text(effect).font(.callout).fixedSize(horizontal: false, vertical: true)
            if plan.canMerge {
                Picker("冲突查看内容", selection: $showsEditor) {
                    Text("本地与云端对比").tag(false)
                    Text("手动合并结果").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                    .disabled(isBusy)
            }
        }
    }

    private var effect: String {
        switch choice {
        case .mine:
            return "采用冲突前的本地完整文件，放弃该文件的入站变化。若还要保留云端部分修改，请选择手动合并。"
        case .theirs:
            return "采用此次冲突的云端完整文件，替换该文件的本地内容。应用前会保留备份。"
        case .manual:
            return "编辑合并结果并移除冲突标记。检查通过后，还需确认写入文件并标记已解决。"
        }
    }

    private func mergeEditor(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("合并结果（尚未写入文件）").font(.headline)
                Spacer()
                if let local = plan.comparison?.local {
                    Button("用本地填充") { draft.replace(local.text); clearReview() }
                }
                if let remote = plan.comparison?.remote {
                    Button("用云端填充") { draft.replace(remote.text); clearReview() }
                }
                Button("恢复当前工作文件") { draft.replace(plan.workingDocument?.text ?? ""); clearReview() }
            }.font(.caption).disabled(isBusy || requiresReload)
            HStack {
                Text("保存编码：" + (plan.comparison?.local.encoding ?? plan.workingDocument?.encoding ?? "未提供"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("手动合并保存换行", selection: $lineEnding) {
                    ForEach(SVNMergeLineEnding.allCases) { ending in Text(ending.title).tag(ending) }
                }.frame(width: 210).disabled(isBusy)
                Spacer()
            }
            ConflictMergeEditor(draft: draft, editable: !isBusy && !requiresReload)
                .frame(height: height).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
            Text("初始内容为当前工作文件，可能含 SVN 冲突标记。填充会替换编辑区内容，可在编辑区按 ⌘Z 撤销。切换对比视图会保留此处草稿。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var binaryComparison: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                binaryPane("本地版本", bytes: plan.localByteCount)
                Divider()
                binaryPane("云端入站版本", bytes: plan.incomingByteCount)
            }.frame(minHeight: 120)
            Text("此文件暂不支持文本并排展示或手动文本合并。可按完整文件保留本地或使用云端；文件字节不会经过文本转码。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func binaryPane(_ title: String, bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "doc").font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.callout)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("仅处理以上文件，应用前备份；确认后标记为已解决，不会自动提交。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") {
                    if draft.isEdited { confirmsDiscard = true } else { close() }
                }.keyboardShortcut(.cancelAction).disabled(isBusy)
                Spacer()
                if isBusy { ProgressView().controlSize(.small); Text("正在核对或应用…").font(.caption).foregroundStyle(.secondary) }
                Button("检查并解决…") { review(choice, draft.text, lineEnding) }
                    .buttonStyle(.borderedProminent).disabled(!canReview).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("conflict-review")
            }
        }.padding(20).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
    }

    private func confirmationText(_ snapshot: SVNConflictResolution) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file)
        var text = "文件：\(snapshot.plan.path)\n处理方式：\(snapshot.choice.title)\n写入大小：\(bytes)"
        if snapshot.choice == .manual { text += "\n保存换行：\(snapshot.lineEnding.title)" }
        return text + "\n\n先备份当前内容及冲突辅助文件，再仅处理此文件的内容冲突并标记为已解决。不会自动提交代码。"
    }
}

/// The native editor owns keystrokes; publishing each edit would rebuild the
/// full comparison view. Publish only the first dirty transition or a fill.
@MainActor
private final class ConflictMergeDraft: ObservableObject {
    var text: String
    @Published private(set) var replacementID = UUID()
    @Published private(set) var isEdited = false
    init(_ text: String) { self.text = Self.normalized(text) }
    func replace(_ text: String) {
        self.text = Self.normalized(text)
        isEdited = true
        replacementID = UUID()
    }
    func edited(_ text: String) {
        self.text = text
        if !isEdited { isEdited = true }
    }
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

private struct ConflictMergeEditor: NSViewRepresentable {
    @ObservedObject var draft: ConflictMergeDraft
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(draft) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let editor = NSTextView(frame: scroll.contentView.bounds)
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.identifier = NSUserInterfaceItemIdentifier("conflict-merge-editor")
        editor.string = draft.text; editor.isEditable = editable
        editor.delegate = context.coordinator
        context.coordinator.appliedReplacement = draft.replacementID
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = editable
        if context.coordinator.appliedReplacement != draft.replacementID {
            context.coordinator.appliedReplacement = draft.replacementID
            if editor.string != draft.text {
                editor.insertText(draft.text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let draft: ConflictMergeDraft
        var appliedReplacement: UUID?
        init(_ draft: ConflictMergeDraft) { self.draft = draft }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            draft.edited(editor.string)
        }
    }
}
