import AppKit
import SwiftUI
import SVNCore

struct RepositoryLoginView: View {
    let request: RepositoryLoginRequest
    @ObservedObject var model: AppModel
    @State private var username: String
    @State private var password = ""
    @FocusState private var field: Field?
    private enum Field { case username, password }

    init(request: RepositoryLoginRequest, model: AppModel) {
        self.request = request
        self.model = model
        _username = State(initialValue: request.username)
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty &&
        !password.contains("\n") && !password.contains("\r")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("登录 SVN 仓库", systemImage: "lock.shield").font(.title2.bold())
            Text(SVNLocation.display(request.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(request.reason).font(.callout)
            VStack(alignment: .leading, spacing: 8) {
                Text("用户名").font(.headline)
                TextField("请输入仓库用户名", text: $username).textFieldStyle(.roundedBorder).focused($field, equals: .username)
                    .onSubmit { field = .password }
                Text("密码").font(.headline).padding(.top, 4)
                SecureField("请输入仓库密码", text: $password).textFieldStyle(.roundedBorder).focused($field, equals: .password)
                    .onSubmit { submit() }
            }
            Label("验证成功后保存到 macOS 钥匙串，后续访问同一仓库自动登录。", systemImage: "key.fill")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { password = ""; model.cancelLogin() }.keyboardShortcut(.cancelAction)
                Button("登录并记住", action: submit).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }.padding(26).frame(width: 500)
            .onAppear { field = username.isEmpty ? .username : .password }
    }

    private func submit() {
        guard canSubmit else { return }
        let value = password
        password = ""
        model.submitLogin(username: username, password: value)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SVN 设置").font(.title2.bold())
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            Text("SVN 命令行路径").font(.headline)
            HStack {
                TextField("/opt/homebrew/bin/svn", text: $model.executablePath).textFieldStyle(.roundedBorder)
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.title = "选择 SVN 可执行文件"
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { model.executablePath = url.path }
                }
            }.disabled(model.busy)
            Label(FileManager.default.isExecutableFile(atPath: model.executablePath) ? "已找到可执行程序" : "请选择已安装的 svn 程序", systemImage: "terminal")
                .foregroundStyle(.secondary).font(.caption)
            Text("需要 SVN 1.14 或以上。应用会自动查找常见安装位置；已有 Homebrew 时可运行 brew install subversion 安装。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            UserIgnoreSettingsView(model: model)
            Divider()
            Text("认证与证书").font(.headline)
            Text("首次浏览仓库时弹窗输入账号密码，验证成功后按仓库保存到 macOS 钥匙串。后续浏览、签出、更新和提交自动使用相应仓库的账号，重启应用后仍可使用。密码通过标准输入传给 SVN，不写入应用偏好或日志。")
                .font(.callout).foregroundStyle(.secondary)
            Text("服务器证书按 SVN 默认规则校验；自签名证书请先在终端核对并建立信任。SSH 仓库使用已有 SSH 密钥与代理，应用不处理交互式 SSH 密码。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("清空未固定的最近记录，保留固定项，不影响磁盘文件。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空最近记录", action: model.clearRecentHistory).disabled(model.busy)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).disabled(model.busy) }
        }.padding(26).frame(width: 700, height: 760)
            .interactiveDismissDisabled(model.busy)
    }
}

struct DiffView: View {
    let title: String
    let text: String
    let context: String
    let fileDiff: FileDiffPresentation?
    @Environment(\.dismiss) private var dismiss
    @State private var findRequest = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: "doc.text.magnifyingglass").font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("查找") { findRequest += 1 }.keyboardShortcut("f", modifiers: .command)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(context).font(.callout).foregroundStyle(.secondary)
            if let fileDiff {
                FileComparisonContent(presentation: fileDiff, findRequest: findRequest)
            } else {
                DiffTextView(text: text, findRequest: findRequest).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }.padding(20).frame(minWidth: fileDiff == nil ? 850 : 1_050, minHeight: fileDiff == nil ? 580 : 700)
    }
}
