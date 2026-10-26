import SwiftUI
import SVNCore

struct WorkingFileDiffView: View {
    @ObservedObject var model: AppModel
    @State private var choice = "base"
    @State private var revision = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.diffFileTarget != nil {
                HStack {
                    Text("对照版本")
                    Picker("对照版本", selection: $choice) {
                        Text("签出基线 BASE").tag("base")
                        Text("云端最新 HEAD").tag("head")
                        Text("指定版本").tag("revision")
                    }.labelsHidden().frame(width: 205)
                    if choice == "revision" {
                        TextField("数字版本号", text: $revision).textFieldStyle(.roundedBorder).frame(width: 115)
                            .onSubmit { load() }
                    }
                    Button("读取对照版本", action: load).disabled(model.diffReloading)
                    if model.diffReloading {
                        ProgressView().controlSize(.small)
                        Button("取消读取", action: model.cancelDiffRead)
                    }
                    Spacer()
                    Text("仅点击读取时访问服务器").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.top, 16)
                if let error = model.diffError {
                    Text("读取未完成，仍显示上一次成功的对照：\n" + error).font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 8)
                }
            }
            DiffView(title: model.diffTitle, text: model.diffText, context: model.diffContext, fileDiff: model.fileDiff)
        }
        .onAppear { choice = model.diffRevisionChoice; model.diffError = nil }
        .onDisappear { model.cancelDiffRead() }
        .sheet(item: $model.loginRequest) { request in
            RepositoryLoginView(request: request, model: model).interactiveDismissDisabled()
        }
    }

    private func load() { model.reloadFileDiff(choice: choice, revisionText: revision) }
}
