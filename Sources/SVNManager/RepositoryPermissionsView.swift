import SwiftUI
import SVNCore

struct RepositoryPermissionTarget: Identifiable {
    let id = UUID()
    let url: String
}

@MainActor
final class RepositoryPermissionsModel: ObservableObject {
    @Published var endpoint = UserDefaults.standard.string(forKey: "permissionManagementEndpoint") ?? ""
    @Published var token = ""
    @Published var inspection: RepositoryPermissionInspection?
    @Published var selectedAccount = ""
    @Published var accountSearch = ""
    @Published var access = RepositoryPermissionAccess.read
    @Published var review: RepositoryPermissionReview?
    @Published var loading = false
    @Published var applying = false
    @Published var message: String?
    @Published var pending: RepositoryPermissionPending?
    var pendingOperation: UUID? { pending?.operationId }
    @Published var acknowledged = false
    private var client: RepositoryPermissionClient?
    private var task: Task<Void, Never>?
    let target: String

    init(target: String) { self.target = target }
    var accounts: [RepositoryPermissionAccount] {
        let term = accountSearch
        return Array((inspection?.accounts ?? []).lazy.filter { term.isEmpty || $0.name.localizedStandardContains(term) }.prefix(200))
    }
    var account: RepositoryPermissionAccount? { inspection?.accounts.first { $0.id == selectedAccount } }
    var canPrepare: Bool { inspection?.writesEnabled == true && account != nil && !loading && pendingOperation == nil }

    func loadToken() {
        task = Task {
            guard let url = try? RepositoryPermissionEndpoint.validated(endpoint) else { return }
            do {
                let value = try await Task.detached { try RepositoryPermissionTokenStore.load(endpoint: url) }.value
                if !Task.isCancelled, token.isEmpty, (try? RepositoryPermissionEndpoint.validated(endpoint)) == url { token = value ?? "" }
            } catch { message = error.localizedDescription }
        }
    }

    func connect() {
        guard !loading else { return }
        loading = true; message = nil; inspection = nil; review = nil; selectedAccount = ""; acknowledged = false
        let endpointText = endpoint, tokenText = token
        task = Task {
            defer { loading = false }
            do {
                let connection = try RepositoryPermissionClient(endpoint: endpointText, token: tokenText)
                let url = connection.endpoint
                try await Task.detached { try RepositoryPermissionTokenStore.save(tokenText, endpoint: url) }.value
                UserDefaults.standard.set(url.absoluteString, forKey: "permissionManagementEndpoint")
                endpoint = url.absoluteString; client = connection
                pending = try await RepositoryPermissionPendingStore.shared.load(endpoint: url)
                inspection = try await connection.inspect(repositoryURL: target)
                message = pendingOperation == nil ? "已读取当前路径及祖先路径的规则。" : "此管理接口有一项授权结果待核对，请先查询结果。"
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }

    func prepare() {
        guard canPrepare, let client, let inspection, let account else { return }
        loading = true; message = nil; review = nil
        task = Task {
            defer { loading = false }
            do { review = try await client.prepare(inspection: inspection, account: account, access: access) }
            catch { message = error.localizedDescription }
        }
    }

    func apply() {
        guard !loading, let client, let reviewed = review, pendingOperation == nil else { return }
        let id = UUID()
        let record = RepositoryPermissionPending(operationId: id, endpoint: client.endpoint, review: reviewed)
        review = nil; acknowledged = false
        loading = true; applying = true; message = nil
        task = Task {
            defer { loading = false; applying = false }
            do {
                try await RepositoryPermissionPendingStore.shared.save(record, endpoint: client.endpoint)
                pending = record
                let receipt = try await client.apply(reviewed, operationId: id)
                try await processReceipt(receipt, client: client)
            } catch { message = error.localizedDescription }
        }
    }

    func queryResult() {
        guard !loading, let client, let pendingOperation else { return }
        loading = true; acknowledged = false; message = nil
        task = Task {
            defer { loading = false }
            do {
                let receipt = try await client.status(operationId: pendingOperation)
                try await processReceipt(receipt, client: client)
            }
            catch { message = error.localizedDescription }
        }
    }

    private func processReceipt(_ receipt: RepositoryPermissionReceipt, client: RepositoryPermissionClient) async throws {
        // This is a separate read even when the server reports a confirmed write.
        let resultScope = pending?.review.repositoryURL ?? target
        let readback = try await client.inspect(repositoryURL: resultScope)
        if (try? RepositoryCredentialScope.canonicalURL(target)) == (try? RepositoryCredentialScope.canonicalURL(resultScope)) {
            inspection = readback
        }
        switch receipt.status {
        case "confirmed":
            try await clearPending(); message = "服务器已确认授权写入，已重新读取操作原路径的规则：\(SVNLocation.display(resultScope))。没有提交任何 SVN 文件。"
        case "rejected":
            try await clearPending(); message = "服务器拒绝了本次授权（\(receipt.code)），已重新读取操作原路径的规则。"
        default: message = "授权结果仍待核对，已重新读取规则；请由管理员核对操作回执后再继续。"
        }
    }

    func refresh() {
        guard !loading, let client else { return }
        loading = true; review = nil
        task = Task {
            defer { loading = false }
            do { inspection = try await client.inspect(repositoryURL: target) }
            catch { message = error.localizedDescription }
        }
    }

    func confirmManualCheck() {
        guard !loading, acknowledged, inspection != nil else { return }
        loading = true
        task = Task {
            defer { loading = false }
            do {
                try await clearPending(); acknowledged = false
                message = "已按管理员人工核对结果解除本机待核对状态。没有重发授权请求。"
            } catch { message = error.localizedDescription }
        }
    }
    func configurationChanged() {
        guard !loading else { return }
        inspection = nil; review = nil; client = nil; selectedAccount = ""; message = nil
        pending = nil; acknowledged = false
    }
    private func clearPending() async throws {
        guard let client, let pending else { return }
        try await RepositoryPermissionPendingStore.shared.remove(endpoint: client.endpoint, operationId: pending.operationId)
        self.pending = nil
    }
    func cancelRead() { if !applying { task?.cancel(); review = nil } }
}

struct RepositoryPermissionsView: View {
    @StateObject private var model: RepositoryPermissionsModel
    @Environment(\.dismiss) private var dismiss
    init(target: RepositoryPermissionTarget) { _model = StateObject(wrappedValue: RepositoryPermissionsModel(target: target.url)) }
    init(model: RepositoryPermissionsModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("仓库权限", systemImage: "person.badge.key.fill").font(.title2.bold())
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.applying)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(SVNLocation.display(model.target)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    GroupBox("内网管理接口") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("https://管理服务器:端口/", text: Binding(get: { model.endpoint }, set: {
                                model.configurationChanged(); model.endpoint = $0
                            })).textFieldStyle(.roundedBorder)
                            HStack {
                                SecureField("独立管理令牌", text: Binding(get: { model.token }, set: {
                                    model.configurationChanged(); model.token = $0
                                })).textFieldStyle(.roundedBorder)
                                Button("连接并读取", action: model.connect)
                            }
                            Text("由服务器管理员配置 HTTPS 接口；管理令牌保存在 macOS 钥匙串，与 SVN 登录密码分开。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8).disabled(model.loading)
                    }
                    if let inspection = model.inspection {
                        HStack {
                            Text("仓库：\(inspection.repositoryName)   路径：\(inspection.path)").font(.headline)
                            Spacer()
                            Button("重新读取", action: model.refresh).disabled(model.loading)
                        }
                        Text("规则从当前路径向子目录和文件继承；子路径自己的规则保留。这里只修改当前路径的一条规则。")
                            .font(.callout).foregroundStyle(.secondary)
                        if !inspection.writesEnabled {
                            Label("服务器当前为只读模式。管理员须先完成隔离测试库验收，再启用权限写入。", systemImage: "lock")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        rules(inspection)
                        if model.pendingOperation == nil {
                            GroupBox("给已有用户或组设置规则") {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("搜索用户或组", text: $model.accountSearch).textFieldStyle(.roundedBorder)
                                    Picker("账号", selection: $model.selectedAccount) {
                                        Text("请选择用户或组").tag("")
                                        ForEach(model.accounts) { Text($0.label).tag($0.id) }
                                    }
                                    if (inspection.accounts.count) > 200 { Text("每次最多显示 200 个匹配账号，可输入名称缩小范围。").font(.caption).foregroundStyle(.secondary) }
                                    Picker("当前路径规则", selection: $model.access) {
                                        ForEach(RepositoryPermissionAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                                    }
                                    Text("“无访问”表示此条规则不授予访问；用户所属组或其他规则仍可能授予访问。“移除”恢复按上级规则继承。")
                                        .font(.caption).foregroundStyle(.secondary)
                                    HStack { Spacer(); Button("检查授权…", action: model.prepare).disabled(!model.canPrepare) }
                                }.padding(8).disabled(model.loading)
                            }
                        }
                    }
                    if let id = model.pendingOperation {
                        GroupBox("授权结果待核对") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("操作编号：\(id.uuidString)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if let pending = model.pending {
                                    Text("原作用范围：\(SVNLocation.display(pending.review.repositoryURL))").textSelection(.enabled)
                                    Text("\(pending.review.accountName) · \(pending.review.newAccess.label)")
                                }
                                Button("查询授权结果", action: model.queryResult).disabled(model.loading)
                                Toggle("管理员已人工核对服务器规则与操作回执", isOn: $model.acknowledged).toggleStyle(.checkbox)
                                Button("解除本机待核对状态", action: model.confirmManualCheck)
                                    .disabled(model.loading || !model.acknowledged || model.inspection == nil)
                            }.padding(8)
                        }
                    }
                    if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(20)
            }
        }
        .frame(minWidth: 800, idealWidth: 900, maxWidth: 1100, minHeight: 600, idealHeight: 720, maxHeight: 850)
        .interactiveDismissDisabled(model.applying)
        .task { model.loadToken() }
        .onDisappear { model.cancelRead() }
        .onChange(of: model.selectedAccount) { _, _ in model.review = nil }
        .onChange(of: model.access) { _, _ in model.review = nil }
        .sheet(item: Binding(get: { model.review.map(PermissionReviewItem.init) }, set: { if $0 == nil { model.review = nil } })) { item in
            VStack(alignment: .leading, spacing: 18) {
                Text("确认修改权限规则").font(.title2.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(SVNLocation.display(item.review.repositoryURL)).textSelection(.enabled)
                        LabeledContent("账号", value: (item.review.accountKind == "group" ? "组 · " : "用户 · ") + item.review.accountName)
                        LabeledContent("当前显式规则", value: item.review.oldAccess?.label ?? "无显式规则（继承上级）")
                        LabeledContent("修改为", value: item.review.newAccess.label)
                        Text("生效起点：\(item.review.path)\n子目录继续继承，保留各子路径自己的规则和其他账号规则。")
                        Text("此处显示单条规则；组成员身份和其他规则可能影响最终访问能力。不会提交任何代码。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxHeight: 340)
                HStack {
                    Button("返回检查") { model.review = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("确认授权", action: model.apply).buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 620)
        }
    }

    private func rules(_ inspection: RepositoryPermissionInspection) -> some View {
        GroupBox("当前路径及上级的权限规则") {
            VStack(alignment: .leading, spacing: 8) {
                if inspection.rules.isEmpty { Text("当前范围没有显式规则").foregroundStyle(.secondary) }
                else {
                    Table(inspection.rules) {
                        TableColumn("用户 / 组") { rule in
                                Text((rule.accountKind == "group" ? "组 · " : rule.accountKind == "everyone" ? "所有人 · " : "用户 · ") + rule.accountName)
                        }
                        TableColumn("规则") { Text($0.access.label) }.width(110)
                        TableColumn("来源路径") { rule in
                                Text(rule.sourcePath + (rule.isInherited ? "（上级）" : "（当前）")).foregroundStyle(.secondary)
                        }
                    }.frame(height: 220)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct PermissionReviewItem: Identifiable {
    let review: RepositoryPermissionReview
    var id: String { review.reviewId }
    init(_ review: RepositoryPermissionReview) { self.review = review }
}
