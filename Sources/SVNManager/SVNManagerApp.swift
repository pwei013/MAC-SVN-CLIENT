import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy {
            Task { @MainActor in
                model.reopenMainWindow?()
                model.alert = "当前 SVN 操作尚未结束。请先等待完成，或使用“取消”停止可取消的操作，再退出应用。"
            }
            return .terminateCancel
        }
        Task { @MainActor in
            let saved = await model.flushProjectStateForTermination()
            if !saved { model.reopenMainWindow?() }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

@main
struct SVNManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SVN 管理", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .frame(minWidth: 1060, minHeight: 700)
                .tint(.indigo)
        }
        .defaultSize(width: 1240, height: 810)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开工作副本…", action: model.chooseWorkingCopy).keyboardShortcut("o").disabled(model.busy)
            }
            CommandGroup(after: .appInfo) {
                Button("SVN 设置…") { model.showSettings = true }.keyboardShortcut(",").disabled(model.busy)
            }
            CommandMenu("SVN") {
                Button("刷新") {
                    if model.screen == .repository { model.browse(model.currentURL.isEmpty ? nil : model.currentURL, forceReload: true) }
                    else { model.refresh() }
                }.keyboardShortcut("r").disabled(model.busy)
                Button("查看差异", action: model.previewDiff).disabled(model.busy || model.changeSelection == nil)
            }
        }
        Window("签出进度", id: "checkout-progress") {
            if let progress = model.checkoutProgress {
                CheckoutProgressView(progress: progress, cancel: model.cancel)
                    .tint(.indigo)
            }
        }
        .defaultSize(width: 860, height: 620)
        Window("更新与提交进度", id: "operation-progress") {
            if let progress = model.operationProgress {
                OperationProgressView(progress: progress, cancel: model.cancel).tint(.indigo)
            }
        }
        .defaultSize(width: 1_060, height: 680)
    }
}
