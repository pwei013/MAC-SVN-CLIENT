import SwiftUI
import SVNCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 330)
        } detail: {
            VStack(spacing: 0) {
                if model.screen == .repository { repositoryView } else { workingCopyView }
                Divider()
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(model.screen == .repository ? "仓库浏览" : "工作副本")
        .toolbar {
            ToolbarItemGroup {
                Button { model.showActivity = true } label: { Label("操作记录", systemImage: "clock.arrow.circlepath") }.disabled(model.busy)
                Button { model.showSettings = true } label: { Label("设置", systemImage: "gearshape") }.disabled(model.busy)
            }
        }
        .alert("操作提示", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("知道了", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showDiff) {
            WorkingFileDiffView(model: model)
        }
        .sheet(item: $model.historySession) { session in HistoryView(session: session, appModel: model) }
        .sheet(item: $model.incomingSession) { session in IncomingUpdatesView(session: session, appModel: model) }
        .sheet(isPresented: $model.showCommit) { commitReview }
        .sheet(isPresented: $model.showActivity) { activityView }
        .sheet(item: $model.unignoreRequest) { request in unignoreReview(request) }
        .sheet(item: $model.directoryIgnoreRequest) { request in
            DirectoryIgnoreSettingsView(model: model, directory: request.directory)
        }
        .sheet(item: Binding(get: { model.showDiff ? nil : model.loginRequest }, set: { model.loginRequest = $0 })) { request in
            RepositoryLoginView(request: request, model: model)
                .interactiveDismissDisabled()
        }
        .onChange(of: model.checkoutProgress?.id) { _, value in
            if value != nil { openWindow(id: "checkout-progress") }
        }
        .onChange(of: model.operationProgress?.id) { _, value in
            if value != nil { openWindow(id: "operation-progress") }
        }
        .task { model.restoreLastProjectIfNeeded() }
        .onAppear {
            model.reopenMainWindow = {
                if let window = NSApp.windows.first(where: { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain && !["签出进度", "更新与提交进度"].contains($0.title) }) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                } else { openWindow(id: "main") }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(.indigo)
                    .frame(width: 46, height: 46).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("SVN 管理").font(.title3.bold())
                    Text("代码，在你掌控之中").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            VStack(alignment: .leading, spacing: 10) {
                Text("连接仓库").font(.headline)
                TextField("https://server/svn/project", text: Binding(
                    get: { SVNLocation.display(model.repositoryURL) }, set: { model.repositoryURL = $0 }), axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder).accessibilityLabel("仓库地址")
                Button(action: { model.browse(forceReload: true) }) {
                    Label("连接并浏览", systemImage: "network").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy || model.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("支持 HTTP(S)、SVN、SSH 和本地仓库").font(.caption2).foregroundStyle(.secondary)
                Text("首次浏览时登录，同一仓库自动记住账号。").font(.caption2).foregroundStyle(.secondary)
                if model.canChangeLogin {
                    Button("更换当前仓库账号…") { model.browse(model.currentURL, forceLogin: true) }
                        .font(.caption).disabled(model.busy)
                }
            }.padding(.horizontal, 18)
            Divider().padding(.vertical, 18)
            VStack(spacing: 5) {
                navigationButton("仓库浏览", symbol: "externaldrive.connected.to.line.below", screen: .repository)
                navigationButton("本地工作副本", symbol: "folder", screen: .workingCopy)
            }.padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if !model.recentWorkingCopies.isEmpty {
                        Text("最近工作副本").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 18)
                        ForEach(model.recentWorkingCopies, id: \.self) { path in
                            recentLocationRow(pinned: model.isWorkingCopyPinned(path),
                                name: URL(fileURLWithPath: path).lastPathComponent, detail: path,
                                open: { model.openWorkingCopy(URL(fileURLWithPath: path)) },
                                togglePin: { model.toggleWorkingCopyPin(path) }) {
                                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }
                        }
                    }
                    if !model.recentRepositories.isEmpty {
                        Text("最近仓库").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 14)
                        ForEach(model.recentRepositories, id: \.self) { url in
                            recentLocationRow(pinned: model.isRepositoryPinned(url),
                                name: SVNLocation.display(url), detail: SVNLocation.display(url),
                                open: { model.browse(url) }, togglePin: { model.toggleRepositoryPin(url) }) {
                                    Text(SVNLocation.display(url)).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            Button(action: model.chooseWorkingCopy) { Label("打开已有工作副本…", systemImage: "folder.badge.plus") }
                .disabled(model.busy).padding(18)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func recentLocationRow<LabelContent: View>(pinned: Bool, name: String, detail: String,
        open: @escaping () -> Void, togglePin: @escaping () -> Void,
        @ViewBuilder label: () -> LabelContent) -> some View {
        HStack(spacing: 6) {
            Button(action: open, label: label).buttonStyle(.plain).help(detail).disabled(model.busy)
            Button(action: togglePin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11)).foregroundStyle(pinned ? Color.indigo : .secondary)
                    .frame(width: 24, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help(pinned ? "取消固定到顶部" : "固定到顶部")
                .accessibilityLabel((pinned ? "取消固定：" : "固定到顶部：") + name)
        }
        .contextMenu {
            Button(pinned ? "取消固定到顶部" : "固定到顶部", systemImage: pinned ? "pin.slash" : "pin", action: togglePin)
        }
    }

    private func navigationButton(_ title: String, symbol: String, screen: Screen) -> some View {
        Button { model.screen = screen } label: {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                .background(model.screen == screen ? Color.indigo.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(model.screen == screen ? Color.indigo : .primary)
        }.buttonStyle(.plain)
    }

    private var repositoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("浏览远程仓库", subtitle: "打开目录，选择项目，签出到你的 Mac。", symbol: "externaldrive.connected.to.line.below")
            if model.currentURL.isEmpty {
                ContentUnavailableView("从一个仓库地址开始", systemImage: "network", description: Text("在左侧输入 SVN 仓库地址，点击“连接并浏览”。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    Button(action: model.goUp) { Image(systemName: "arrow.up") }.help("上一级目录")
                    Image(systemName: "link").foregroundStyle(.secondary)
                    Text(SVNLocation.display(model.currentURL)).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button { model.browse(model.currentURL, forceReload: true) } label: { Image(systemName: "arrow.clockwise") }.help("刷新目录")
                }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 24)
                    .disabled(model.busy)
                HStack {
                    Text(model.repositoryListSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Toggle("搜索子目录", isOn: $model.searchesSubdirectories).toggleStyle(.checkbox).font(.caption)
                        .disabled(model.busy).onChange(of: model.searchesSubdirectories) { _, _ in model.repositorySearchScopeChanged() }
                    Toggle("只显示文件夹", isOn: $model.repositoryDirectoriesOnly).toggleStyle(.checkbox).font(.caption)
                        .disabled(model.busy).onChange(of: model.repositoryDirectoriesOnly) { _, _ in model.repositoryDirectoriesOnlyChanged() }
                    TextField(model.searchesSubdirectories ? "名称或相对路径" : "筛选名称", text: $model.repositorySearch)
                        .textFieldStyle(.roundedBorder).frame(width: 190).disabled(model.busy)
                        .onSubmit { model.searchRepository() }
                    if model.searchesSubdirectories {
                        Button("搜索", action: model.searchRepository)
                            .disabled(model.busy || model.repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 14)
                if let query = model.completedRepositorySearch {
                    HStack {
                        Text("搜索范围：当前目录及所有子目录 · 关键词：\(query)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(query)
                        Spacer()
                        Button("返回当前目录", action: model.clearRepositorySearch).controlSize(.small).disabled(model.busy)
                    }.padding(.horizontal, 24).padding(.bottom, 10)
                }
                RepositoryContentsView(location: model.currentURL, entries: model.filteredEntries, busy: model.busy,
                    searchQuery: model.completedRepositorySearch,
                    onOpen: model.openEntry, onReveal: model.revealRepositoryEntry, onCheckout: { model.checkout($0) }, onHistory: { entry in
                        do { model.openHistory(url: try entry.map { try SVNLocation.child($0.name, of: model.currentURL) } ?? model.currentURL) }
                        catch { model.alert = error.localizedDescription }
                    })
                    .overlay {
                        if model.isSearchingRepository || model.loadingRepositoryURL != nil {
                            ZStack {
                                Rectangle().fill(.regularMaterial)
                                VStack(spacing: 12) {
                                    ProgressView()
                                    Text(model.isSearchingRepository ? "正在搜索子目录…" : "正在打开目录…").font(.headline)
                                    Text(model.isSearchingRepository ? "读取目录清单，不下载文件内容" :
                                        (URL(string: model.loadingRepositoryURL ?? "")?.lastPathComponent ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if model.isSearchingRepository { Button("取消搜索", action: model.cancel) }
                                }.padding(24)
                            }
                        }
                    }
            }
        }
    }

    private var workingCopyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("管理本地变更", subtitle: "检查差异，选择要提交的文件，为每次修改留下记录。", symbol: "folder.badge.gearshape")
            if let directory = model.workingDirectory {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(directory.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(SVNLocation.display(model.workingInfo?.url ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(action: model.revealWorkingCopy) { Image(systemName: "folder") }.help("在 Finder 中打开")
                    Button("更换…", action: model.chooseWorkingCopy).disabled(model.busy)
                }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Button(action: model.refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    Button(action: model.update) { Label("更新", systemImage: "arrow.down.circle") }
                    Button("查看差异", action: model.previewDiff).disabled(model.changeSelection == nil)
                        .help("比较本地修改与签出基线（BASE）")
                    Button { prepareAdd(model.addablePaths) } label: { Label("Add", systemImage: "plus.circle") }
                        .disabled(model.addablePaths.isEmpty)
                        .help("将勾选或选中的未跟踪项添加到 SVN 版本控制")
                    Menu("更多操作") {
                        Button("Add 到版本控制…") { prepareAdd(model.addablePaths) }
                            .disabled(model.addablePaths.isEmpty)
                        Button("将勾选的缺失路径标记为删除…") { showDeleteConfirmation = true }
                            .disabled(!model.checkedChanges.contains { $0.item == "missing" })
                    }
                    Spacer()
                    TextField("筛选路径", text: $model.changeSearch).textFieldStyle(.roundedBorder).frame(width: 160)
                }.padding(.horizontal, 24).padding(.vertical, 14).disabled(model.busy)
                HStack {
                    Toggle("显示已忽略文件", isOn: Binding(get: { model.showIgnoredFiles }, set: model.setShowIgnoredFiles))
                        .toggleStyle(.checkbox).disabled(model.busy)
                        .help("显示 SVN 用户全局过滤及目录属性忽略的文件和文件夹；忽略项不能直接 Add 或提交。")
                    Button("提交历史") { model.openWorkingHistory() }.disabled(model.busy)
                    Button("检查云端更新", action: model.checkIncomingUpdates).disabled(model.busy)
                    Spacer()
                    Button("目录忽略属性…") { model.editDirectoryIgnores() }.disabled(model.busy)
                        .help("查看和编辑当前工作目录的忽略规则及继承来源")
                }.font(.callout).padding(.horizontal, 24).padding(.bottom, 10)
                WorkingCopyFilterBar(model: model)
                changeTable
                commitComposer
            } else {
                ContentUnavailableView {
                    Label("打开你的工作副本", systemImage: "folder.badge.plus")
                } description: {
                    Text("签出仓库后会自动打开，也可以选择已经签出的本地目录。")
                } actions: {
                    Button("选择工作副本…", action: model.chooseWorkingCopy).buttonStyle(.borderedProminent).disabled(model.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Add 到 SVN 版本控制？", isPresented: $showAddConfirmation, titleVisibility: .visible) {
            Button("Add 并刷新清单") { model.add(paths: pendingAddPaths) }
        } message: {
            Text("将添加 \(pendingAddPaths.count) 项：\n\(pendingAddPaths.prefix(6).joined(separator: "\n"))\(pendingAddPaths.count > 6 ? "\n…" : "")\n\n添加文件夹时会递归处理其中未被 SVN 忽略的文件。Add 后请检查新增清单，再勾选提交。")
        }
        .confirmationDialog("将缺失路径标记为删除？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("标记为待删除", action: model.markMissing)
        } message: { Text("此操作只处理已勾选且本地确实缺失的路径；提交后才会从仓库中删除。") }
    }

    @State private var showAddConfirmation = false
    @State private var pendingAddPaths: [String] = []
    @State private var showDeleteConfirmation = false

    private func prepareAdd(_ paths: [String]) {
        guard !model.busy, !paths.isEmpty else { return }
        pendingAddPaths = paths
        showAddConfirmation = true
    }

    private var changeTable: some View {
        Table(model.filteredChanges, selection: $model.changeSelection) {
            TableColumn("提交") { change in
                Toggle("选择 \(change.path)", isOn: Binding(
                    get: { model.checkedPaths.contains(change.path) },
                    set: { if $0 { model.checkedPaths.insert(change.path) } else { model.checkedPaths.remove(change.path) } }
                )).labelsHidden().toggleStyle(.checkbox)
                    .disabled(model.busy || !change.canCheck)
            }.width(42)
            TableColumn("状态") { change in
                Text(change.label).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                    .foregroundStyle(statusColor(change)).background(statusColor(change).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
            }.width(84)
            TableColumn("文件路径") { change in
                HStack(spacing: 8) {
                    FileTypeIcon(path: change.path, kind: change.nodeKind)
                    Text(change.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }.help(change.path)
            }.width(min: 280, ideal: 520)
        }
        .contextMenu(forSelectionType: String.self) { selected in
            if selected.count == 1, let path = selected.first {
                Button { model.openLocalChange(path, using: .finder) } label: {
                    Label("在访达中打开", systemImage: "folder")
                }.disabled(model.busy)
                    .help("文件夹直接打开，文件在所在目录中选中")
                Button { model.openLocalChange(path, using: .visualStudioCode) } label: {
                    Label("在 VS Code 中打开", systemImage: "chevron.left.forwardslash.chevron.right")
                }.disabled(model.busy)
                Divider()
                Button("提交历史") { model.openWorkingHistory(path) }
                    .disabled(model.busy || !model.changes.contains(where: { $0.path == path && !["unversioned", "ignored", "added"].contains($0.item) }))
                Button { model.previewCloudDiff(path) } label: {
                    Label("查看差异", systemImage: "doc.text.magnifyingglass")
                }.disabled(model.busy || !model.canCompareWithCloud(path))
                    .help("比较已版本化的本地文件与云端最新版本（HEAD）")
                Divider()
            }
            let paths = model.changes.filter { selected.contains($0.path) && $0.item == "unversioned" }.map(\.path)
            Button { prepareAdd(paths) } label: { Label("Add 到版本控制…", systemImage: "plus") }
                .disabled(model.busy || paths.isEmpty)
            if paths.count == 1, let path = paths.first {
                let suggestions = model.ignoreSuggestions(for: path)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(SVNIgnoreScope.allCases) { scope in
                            Menu(scope.title) {
                                let scopedSuggestions = model.ignoreSuggestions(for: path, scope: scope)
                                ForEach(scopedSuggestions) { suggestion in
                                    Button(suggestion.title) { model.ignoreUnversioned(path, using: suggestion, scope: scope) }
                                }
                                Divider()
                                if let property = scope.propertyName {
                                    Text("写入 \(property)，提交目录后共享")
                                    let parent = (path as NSString).deletingLastPathComponent
                                    Text("所在目录：" + (parent.isEmpty ? "当前工作目录" : parent))
                                } else {
                                    Text("写入 SVN 用户全局配置，所有工作副本生效")
                                    if !model.globalIgnorePatterns.isEmpty { Text("同时迁移旧版工具规则到用户配置") }
                                }
                                if scopedSuggestions.contains(where: \.usesWhitespaceWildcard) {
                                    Text("名称中的空白已替换为 ? 通配符")
                                }
                            }
                        }
                        Divider()
                        Text("当前目录指所选项目的所在目录")
                        Text("仅忽略未跟踪项，同名文件和文件夹均适用")
                    } label: { Label("忽略", systemImage: "eye.slash") }
                        .disabled(model.busy)
                }
            }
            if selected.count == 1,
               let path = model.changes.first(where: { selected.contains($0.path) && $0.item == "ignored" })?.path {
                Button { model.prepareUnignore(path) } label: { Label("取消忽略…", systemImage: "eye") }
                    .disabled(model.busy)
            }
            if selected.count == 1, let path = selected.first,
               let target = model.directoryIgnoreTarget(for: path) {
                Divider()
                Button(target.isSelectedDirectory ? "目录忽略属性…" : "所在目录忽略属性…") {
                    model.editDirectoryIgnores(at: target.directory)
                }.disabled(model.busy)
            }
        } primaryAction: { selected in
            guard !model.busy, !model.isFilteringChanges, let path = model.changes.first(where: { selected.contains($0.path) })?.path else { return }
            model.changeSelection = path
            model.previewDiff()
        }
        .overlay {
            if model.isFilteringChanges {
                ProgressView("正在筛选…").padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if model.changes.isEmpty {
                ContentUnavailableView("工作副本很干净", systemImage: "checkmark.circle", description: Text("没有待提交的本地变更。"))
                    .allowsHitTesting(false)
            } else if model.filteredChanges.isEmpty {
                ContentUnavailableView("没有匹配的项目", systemImage: "line.3.horizontal.decrease.circle", description: Text("切换状态或类型，或清除路径筛选。原有提交勾选已保留。"))
                    .allowsHitTesting(false)
            }
        }
        .disabled(model.busy || model.isFilteringChanges)
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("提交说明").font(.headline)
                Spacer()
                Button("勾选可提交项", action: model.checkVisibleCommittableChanges)
                    .disabled(model.isFilteringChanges).help("勾选当前筛选结果中的可提交项目，保留其他勾选")
                Button("清空勾选") { model.checkedPaths = [] }
            }.font(.caption).disabled(model.busy)
            TextEditor(text: $model.commitMessage).font(.body).scrollContentBackground(.hidden)
                .padding(7).frame(height: 68).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty { Text("说明本次修改的内容与原因…").foregroundStyle(.tertiary).padding(12).allowsHitTesting(false) }
                }.disabled(model.busy)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.workingCopySummary) · 已勾选 \(model.checkedPaths.count) 项").font(.caption)
                    if model.hiddenCheckedCount > 0 {
                        Text("其中 \(model.hiddenCheckedCount) 项不在当前筛选结果中，提交前可在检查清单中核对。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text("未跟踪项先选中或勾选，再点 Add；冲突需先用 SVN 工具处理。").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showCommit = true } label: { Label("检查并提交…", systemImage: "arrow.up.circle.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy || !model.committable || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20)
    }

    private var commitReview: some View {
        CommitReviewView(repositoryURL: model.workingInfo?.url ?? "", changes: model.checkedChanges,
                         message: model.commitMessage, isBusy: model.busy, statusColor: statusColor,
                         checkUpdates: model.checkIncomingUpdates, goBack: { model.showCommit = false }, commit: model.commit)
    }

    private func unignoreReview(_ request: UnignoreRequest) -> some View {
        let plan = request.plan
        return VStack(alignment: .leading, spacing: 16) {
            Text("取消忽略？").font(.title2.bold())
            Text(plan.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text("将移除以下来源中匹配该项目的规则：")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !plan.appPatterns.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("旧版工具忽略规则").font(.headline)
                            Text("尚未迁移的旧设置，仅影响本工具").font(.caption).foregroundStyle(.secondary)
                            Text(plan.appPatterns.joined(separator: "\n")).font(.system(.body, design: .monospaced))
                        }
                    }
                    if let config = plan.configuration {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("SVN 用户配置").font(.headline)
                            Text(config.file.path).font(.system(.caption, design: .monospaced))
                            Text(config.sourceDescription).font(.caption).foregroundStyle(.secondary)
                            Text("影响使用该配置的 SVN 客户端，写入前保留原文件备份").font(.caption).foregroundStyle(.secondary)
                            Text(config.removedPatterns.joined(separator: "\n")).font(.system(.body, design: .monospaced))
                        }
                    }
                    ForEach(plan.properties) { edit in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("目录属性：\(edit.name)").font(.headline)
                            Text(edit.directory.path).font(.system(.caption, design: .monospaced))
                            Text(edit.name == "svn:ignore" ? "影响该目录直接包含的未跟踪项" : "影响该目录及其子目录中的未跟踪项")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(edit.removedPatterns.joined(separator: "\n")).font(.system(.body, design: .monospaced))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }.frame(minHeight: 100, maxHeight: 340)
            Text("匹配这些规则的其他项目也会恢复显示。目录属性修改会保留为本地变更；取消忽略不会自动 Add 或提交。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.unignoreRequest = nil }.keyboardShortcut(.cancelAction)
                Button("取消忽略并刷新") { model.confirmUnignore(request) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(26).frame(width: 620)
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("操作记录").font(.title2.bold())
            List(model.activities) { activity in
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    Text(activity.message).foregroundStyle(activity.failed ? Color.red : .primary).textSelection(.enabled)
                }.padding(.vertical, 5)
            }.frame(minHeight: 300)
            HStack { Spacer(); Button("完成") { model.showActivity = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 680, height: 480)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small).scaleEffect(0.8) }
            else { Circle().fill(.green).frame(width: 6, height: 6) }
            Text(model.operation).font(.caption).lineLimit(1)
            if let warning = model.projectStateWarning {
                Label("草稿未保存", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).help(warning)
            }
            Spacer()
            if model.checkoutProgress != nil {
                Button("签出进度…") { openWindow(id: "checkout-progress") }.controlSize(.small)
            }
            if let progress = model.operationProgress {
                Button("\(progress.name)进度…") { openWindow(id: "operation-progress") }.controlSize(.small)
            }
            if model.canCancel { Button("取消", action: model.cancel).controlSize(.small) }
            Text("SVN · macOS").font(.caption2).foregroundStyle(.tertiary)
        }.padding(.horizontal, 20).frame(height: 34)
    }

    private func pageHeader(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 25, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.indigo.opacity(0.6))
        }.padding(24)
    }

    private func statusColor(_ change: WorkingCopyChange) -> Color {
        if change.treeConflicted || ["conflicted", "obstructed"].contains(change.item) || change.properties == "conflicted" { return .red }
        switch change.item {
        case "added": return .green
        case "deleted", "missing": return .orange
        case "unversioned", "ignored": return .secondary
        default: return .indigo
        }
    }
}
