import SwiftUI
import SVNCore

private struct OperationBatch {
    var started = false
    var total: Int?
    var records: [SVNOperationRecord] = []
    var processed: Int?
    var completed = false
    var revision: String?
    var metadata: [SVNOperationMetadata] = []
    var notice: String?
}

private final class OperationEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var batch = OperationBatch()
    func receive(_ event: SVNOperationEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .started(let total): batch.started = true; batch.total = total
        case let .output(records, processed):
            batch.records.append(contentsOf: records)
            if batch.records.count > 10_000 { batch.records.removeFirst(batch.records.count - 10_000) }
            batch.processed = processed
        case .commandCompleted(let revision): batch.completed = true; batch.revision = revision
        case .metadata(let values): batch.metadata.append(contentsOf: values)
        case .notice(let value): batch.notice = value
        }
    }
    func drain() -> OperationBatch {
        lock.lock(); defer { lock.unlock() }
        let result = batch; batch = OperationBatch(); return result
    }
}

@MainActor
final class OperationProgressModel: ObservableObject, Identifiable {
    enum Phase { case preparing, running, inspecting, succeeded, warning, failed, cancelled }
    let id = UUID()
    let kind: SVNOperationKind
    let directory: URL
    @Published private(set) var phase = Phase.preparing
    @Published private(set) var total: Int?
    @Published private(set) var processed = 0
    @Published private(set) var records: [SVNOperationRecord] = []
    @Published private(set) var metadata: [String: SVNOperationMetadata] = [:]
    @Published private(set) var detail = "正在验证仓库账号和本地状态…"
    @Published private(set) var revision: String?
    private(set) var commandCompleted = false
    private var commandStarted = false
    private var commitRejected = false
    private var notice: String?
    private nonisolated let buffer = OperationEventBuffer()
    private var updates: Task<Void, Never>?

    init(kind: SVNOperationKind, directory: URL) { self.kind = kind; self.directory = directory }
    var name: String { kind == .update ? "更新" : "提交" }
    var running: Bool { [.preparing, .running, .inspecting].contains(phase) }
    var percent: Int? {
        if commandCompleted { return 100 }
        guard kind == .commit, let total, total > 0, phase != .preparing else { return nil }
        return min(99, Int(Double(processed) / Double(total) * 100))
    }
    var title: String {
        switch phase {
        case .preparing: return "准备\(name)"
        case .running: return "正在\(name)代码"
        case .inspecting: return "\(name)已完成，正在补全信息和刷新状态"
        case .succeeded: return "\(name)完成"
        case .warning: return "\(name)已完成，请检查提示"
        case .failed: return kind == .commit ? (commitRejected ? "提交被拒绝" : (commandStarted ? "提交结果待核实" : "提交未开始")) : "更新未完整完成"
        case .cancelled: return "\(name)已取消"
        }
    }

    nonisolated func receive(_ event: SVNOperationEvent) { buffer.receive(event) }
    func startUpdates() {
        updates = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                self?.flush()
            }
        }
    }
    private func flush() {
        let value = buffer.drain()
        if value.started {
            commandStarted = true
            total = value.total; phase = .running
            detail = kind == .update ? "正在接收文件；下载完成后从本地 SVN 元数据批量补全最后提交人和日期。" :
                "正在发送勾选的文件；等待服务器确认提交版本。"
        }
        if let count = value.processed { processed = count }
        if !value.records.isEmpty {
            records.append(contentsOf: value.records)
            if records.count > 10_000 { records.removeFirst(records.count - 10_000) }
        }
        if value.completed {
            commandCompleted = true; revision = value.revision; phase = .inspecting
            if kind == .commit, let total { processed = total }
            detail = kind == .update ? "更新命令已完成，正在补全文件提交信息并检查本地状态。" : "服务器已确认提交，正在检查本地状态。"
        }
        if !value.metadata.isEmpty {
            var result = metadata
            for item in value.metadata { result[item.path] = item }
            metadata = result
        }
        if let note = value.notice { notice = note; detail = note }
    }
    func finish(error: Error? = nil, summary: String? = nil, warning: Bool = false) {
        updates?.cancel(); updates = nil; flush()
        if let error {
            commitRejected = (error as? SVNCommitFailure)?.definitelyRejected == true
            phase = commandCompleted ? .warning : (error is CancellationError ? .cancelled : .failed)
            detail = commandCompleted ? "SVN 已确认\(name)完成。\n\(error.localizedDescription)" :
                (error is CancellationError ? (commandStarted ? "操作已取消，本地可能已有部分更新，请刷新检查。" : "操作在执行前已取消。") : error.localizedDescription)
        } else {
            phase = notice == nil && !warning ? .succeeded : .warning
            detail = [summary, notice].compactMap { $0 }.joined(separator: "\n")
            if detail.isEmpty { detail = "\(name)已完成。" }
        }
    }
}

struct OperationProgressView: View {
    @ObservedObject var progress: OperationProgressModel
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var followsLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.title).font(.title2.bold())
                    Label(progress.directory.path, systemImage: "folder").font(.caption).textSelection(.enabled)
                }
                Spacer()
                if let percent = progress.percent { Text("\(percent)%").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit() }
                else if progress.running { ProgressView().controlSize(.small).padding(8) }
            }
            if let percent = progress.percent { ProgressView(value: Double(percent), total: 100) }
            else if progress.running { ProgressView().progressViewStyle(.linear) }
            HStack {
                Text(progress.total.map { "已处理 \(progress.processed) / \($0) 项" } ?? "已收到 \(progress.processed) 项文件和目录通知")
                Spacer()
                if let revision = progress.revision { Text("版本 r\(revision)") }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(progress.detail).font(.callout).foregroundStyle([.warning, .failed].contains(progress.phase) ? Color.orange : .secondary)
                .lineLimit(4).textSelection(.enabled)
            HStack {
                Text("\(progress.name)记录").font(.headline)
                Spacer()
                Toggle("自动滚动到最新文件", isOn: $followsLatest).toggleStyle(.checkbox).font(.caption)
            }
            HStack {
                Text("操作").frame(width: 60, alignment: .leading)
                Text("文件路径 / SVN 消息").frame(maxWidth: .infinity, alignment: .leading)
                if progress.kind == .update {
                    Text("最后提交人").frame(width: 110, alignment: .leading)
                    Text("最后提交日期").frame(width: 160, alignment: .leading)
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollViewReader { proxy in
                List(progress.records) { record in
                    HStack(alignment: .top) {
                        Text(record.action).foregroundStyle(record.action == "冲突" ? Color.orange : Color.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(record.path.isEmpty ? record.message : record.path)
                            .font(.system(size: 12, design: .monospaced)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).help(record.message)
                        if progress.kind == .update {
                            Text(author(record)).frame(width: 110, alignment: .leading).lineLimit(1)
                            Text(date(record))
                                .frame(width: 160, alignment: .leading).monospacedDigit().lineLimit(1)
                        }
                    }.font(.caption).textSelection(.enabled).id(record.id)
                }.listStyle(.inset).border(Color.secondary.opacity(0.2))
                    .overlay { if progress.records.isEmpty { Text("等待 SVN 文件输出…").foregroundStyle(.secondary) } }
                    .onChange(of: progress.records.last?.id) { _, _ in scroll(proxy) }
                    .onChange(of: followsLatest) { _, _ in scroll(proxy) }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.kind == .update ? "保留最近 10,000 条记录；日期为文件最后提交时间，按本机时区显示。" : "保留最近 10,000 条记录。")
                    Text(progress.kind == .update ? "更新不预先遍历统计总数；SVN 确认完成后显示 100%。已删除项目不显示旧提交人。" :
                        "发送通知不等于提交成功；服务器确认版本后显示 100%，提交阶段不提供中断。")
                }.font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if progress.running && progress.kind == .update { Button(progress.commandCompleted ? "停止信息读取" : "取消更新", role: .cancel, action: cancel) }
                Button(progress.running ? "隐藏窗口" : "关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 940, minHeight: 560)
    }

    private func author(_ record: SVNOperationRecord) -> String {
        if record.path.isEmpty { return "—" }
        if record.deleted { return "已删除" }
        if let value = progress.metadata[record.path], !value.author.isEmpty { return value.author }
        return progress.running ? "待补全" : "未提供"
    }
    private func date(_ record: SVNOperationRecord) -> String {
        guard !record.deleted, let value = progress.metadata[record.path], !value.date.isEmpty else { return "—" }
        return value.date
    }
    private func scroll(_ proxy: ScrollViewProxy) {
        if followsLatest, let last = progress.records.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}
