import Foundation
import SwiftUI
import SVNCore

private struct CheckoutBatch {
    var totalItems: Int?
    var revision: String?
    var completedItems: Int?
    var lines: [String] = []
    var completed = false
}

/// The pipe reader only appends here. It never waits for the main thread to draw.
private final class CheckoutEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var batch = CheckoutBatch()

    func receive(_ event: CheckoutEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case let .started(totalItems, revision):
            batch.totalItems = totalItems
            batch.revision = revision
        case let .output(lines, completedItems):
            batch.lines.append(contentsOf: lines)
            batch.completedItems = completedItems
        case .completed: batch.completed = true
        }
    }

    func drain() -> CheckoutBatch {
        lock.lock()
        defer { lock.unlock() }
        let value = batch
        batch = CheckoutBatch()
        return value
    }
}

struct CheckoutLogLine: Identifiable {
    let id: Int
    let text: String
}

@MainActor
final class CheckoutProgressModel: ObservableObject, Identifiable {
    enum Phase { case preparing, downloading, inspecting, succeeded, failed, cancelled }
    let id = UUID()
    let remote: String
    let destination: URL
    @Published private(set) var phase = Phase.preparing
    @Published private(set) var totalItems = 0
    @Published private(set) var completedItems = 0
    @Published private(set) var revision = ""
    @Published private(set) var lines: [CheckoutLogLine] = []
    @Published private(set) var detail = "正在验证仓库并统计文件和目录…"
    private(set) var checkoutCompleted = false
    private nonisolated let buffer = CheckoutEventBuffer()
    private var updates: Task<Void, Never>?

    init(remote: String, destination: URL) {
        self.remote = remote
        self.destination = destination
    }

    var running: Bool { [.preparing, .downloading, .inspecting].contains(phase) }
    var percent: Int {
        if checkoutCompleted { return 100 }
        guard totalItems > 0 else { return 0 }
        return min(99, Int(Double(completedItems) / Double(totalItems) * 100))
    }
    var title: String {
        switch phase {
        case .preparing: return "准备签出"
        case .downloading: return "正在签出代码"
        case .inspecting: return "签出完成，正在读取工作副本"
        case .succeeded: return "签出完成"
        case .failed: return checkoutCompleted ? "签出完成，本地状态读取失败" : "签出失败"
        case .cancelled: return "签出已取消"
        }
    }

    nonisolated func receive(_ event: CheckoutEvent) { buffer.receive(event) }

    func startUpdates() {
        updates = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { break }
                self?.flush()
            }
        }
    }

    private func flush() {
        let batch = buffer.drain()
        if let total = batch.totalItems {
            totalItems = total
            revision = batch.revision ?? ""
            phase = .downloading
            detail = total == 0 ? "空目录，正在创建工作副本…" : "正在接收文件和目录…"
        }
        if let count = batch.completedItems { completedItems = count }
        if !batch.lines.isEmpty {
            let first = lines.count
            lines.append(contentsOf: batch.lines.enumerated().map { CheckoutLogLine(id: first + $0.offset, text: $0.element) })
        }
        if batch.completed {
            checkoutCompleted = true
            completedItems = totalItems
            phase = .inspecting
            detail = "所有文件已签出，正在检查本地状态…"
        }
    }

    func finish(error: Error? = nil) {
        updates?.cancel()
        updates = nil
        flush()
        if let error {
            if error is CancellationError {
                phase = .cancelled
                detail = checkoutCompleted ? "代码已签出，本地状态检查已取消。" : "本机可能已有部分文件，请检查目标目录。"
            } else {
                phase = .failed
                detail = error.localizedDescription
            }
        } else {
            phase = .succeeded
            detail = "代码已保存到所选目录。"
        }
    }
}

struct CheckoutProgressView: View {
    @ObservedObject var progress: CheckoutProgressModel
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var followsLatest = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.title).font(.title2.bold())
                    Text(SVNLocation.display(progress.remote)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Label(progress.destination.path, systemImage: "folder").font(.caption).textSelection(.enabled)
                }
                Spacer()
                if progress.phase == .preparing {
                    ProgressView().controlSize(.small).padding(8)
                } else {
                    Text("\(progress.percent)%").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            if progress.phase == .preparing { ProgressView().progressViewStyle(.linear) }
            else { ProgressView(value: Double(progress.percent), total: 100).tint(progress.phase == .failed ? .red : .indigo) }
            HStack {
                Text(progress.phase == .preparing ? "正在统计签出清单…" : "已处理 \(progress.completedItems) / \(progress.totalItems) 项（文件和目录）")
                Spacer()
                if !progress.revision.isEmpty { Text("版本 r\(progress.revision)") }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(progress.detail).font(.callout).foregroundStyle(progress.phase == .failed ? Color.red : .secondary)
                .textSelection(.enabled).lineLimit(4)
            HStack {
                Text("签出记录").font(.headline)
                Spacer()
                Toggle("自动滚动到最新文件", isOn: $followsLatest).toggleStyle(.checkbox).font(.caption)
            }
            ScrollViewReader { proxy in
                List(progress.lines) { line in
                    Text(line.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                }
                .listStyle(.inset).border(Color.secondary.opacity(0.2))
                .overlay {
                    if progress.lines.isEmpty { Text("等待 SVN 输出…").font(.callout).foregroundStyle(.secondary) }
                }
                .onChange(of: progress.lines.count) { _, _ in
                    if followsLatest, let last = progress.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: followsLatest) { _, follows in
                    if follows, let last = progress.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                Text("进度按项目数量计算，签出成功后显示 100%。").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if progress.running { Button("取消签出", role: .cancel, action: cancel) }
                else { Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(24).frame(minWidth: 760, minHeight: 540)
    }
}
