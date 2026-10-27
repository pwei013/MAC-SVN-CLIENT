import Foundation

public enum SVNCommitFailureKind: Sendable, Equatable { case outOfDate, missingPath, authorization, conflict, hook, locked, invalidPath, workingCopy, localFile, network, postCommit, unknown }

public struct SVNCommitFailure: LocalizedError, Sendable {
    public let kind: SVNCommitFailureKind
    public let reason: String
    public let suggestion: String
    public let details: String
    public let definitelyRejected: Bool
    public var errorDescription: String? {
        "\(definitelyRejected ? "提交被拒绝" : "提交结果需核实")：\(reason)\n\(suggestion)\n\nSVN 诊断：\n\(details)"
    }

    public static func diagnose(_ error: Error) -> SVNCommitFailure {
        let detail = String(error.localizedDescription.prefix(4_000))
        let matches = codePattern.matches(in: detail, range: NSRange(detail.startIndex..., in: detail))
        let codes = Set(matches.compactMap { Range($0.range, in: detail).map { String(detail[$0]) } })
        func has(_ values: String...) -> Bool { !codes.isDisjoint(with: values) }
        func failure(_ kind: SVNCommitFailureKind, _ reason: String, _ suggestion: String, rejected: Bool = true) -> SVNCommitFailure {
            SVNCommitFailure(kind: kind, reason: reason, suggestion: suggestion, details: detail, definitelyRejected: rejected)
        }
        if has("E165007") {
            return failure(.postCommit, "服务器报告提交后钩子执行失败", "新版本可能已经生成。请先核对提交历史和工作副本，不要重复提交。", rejected: false)
        }
        if has("E000013", "E000002", "E000028", "E155010") {
            let reason = has("E000028") ? "本地磁盘空间不足" : (has("E000013") ? "本地文件访问权限不足" : "本地文件或工作副本路径不存在")
            return failure(.localFile, reason, "请检查下方具体本地路径、文件权限及磁盘空间，刷新清单后再提交。", rejected: false)
        }
        if has("E155011", "E160028", "E160042", "E170004") {
            let missing = has("E160013")
            return failure(.outOfDate, missing ? "版本或路径不一致，服务器同时报告目标路径不存在" : "文件或父目录版本已过期",
                missing ? "请检查下方具体路径、父目录及云端状态；待新增文件也可能遇到目录变化或路径兼容问题。确认原因后再更新或调整路径，保留本地修改。" :
                    "请先更新工作副本，处理冲突后重新检查提交清单。待新增文件也依赖父目录的有效版本。")
        }
        if has("E220004", "E220001", "E175013", "E170001", "E215003", "E215004") {
            return failure(.authorization, "身份验证或仓库访问权限不足", "请核对当前仓库账号及具体路径的写入权限；需要时更换账号或联系仓库管理员。")
        }
        if has("E165001") {
            return failure(.hook, "服务器钩子拒绝提交", "请按下方钩子返回的具体原因调整文件或提交说明；客户端不会自动重试。")
        }
        if has("E155015", "E160024", "E155013") {
            return failure(.conflict, "存在未解决的文件、属性或目录冲突", "请先解决冲突并刷新状态，再重新选择要提交的文件。")
        }
        if has("E160013") {
            return failure(.missingPath, "服务器未找到提交涉及的路径", "请核对下方文件及父目录是否存在、是否被移动或删除，以及文件名是否能被服务器正确处理。")
        }
        if has("E160035", "E160036", "E160037", "E160038", "E160039", "E170007") {
            return failure(.locked, "仓库文件锁或锁令牌不符合要求", "请核对文件锁的持有人和当前工作副本的锁令牌，再处理锁或联系管理员。")
        }
        if has("E155004", "E155037") {
            return failure(.workingCopy, "本地工作副本被锁定或上次操作尚未完成", "请先确认没有其他 SVN 操作正在运行，再检查工作副本并按需执行 Cleanup。")
        }
        if has("E125001", "E125002", "E125007", "E155022", "E160020", "E175005", "E200009") {
            return failure(.invalidPath, "路径无效、同名路径已存在或目标不适用于本次操作", "请核对下方具体文件名、目录及本地状态，确认后再提交。")
        }
        let lower = detail.lowercased()
        if ["connection reset", "connection refused", "timed out", "could not resolve", "unable to connect", "connection was closed", "certificate verification", "ssl handshake"].contains(where: lower.contains) {
            return failure(.network, "连接、超时或证书验证异常", "服务器是否接收提交尚未确认。恢复连接后先核对提交历史与本地状态，再决定后续操作。", rejected: false)
        }
        return failure(.unknown, "SVN 未完整确认提交结果", "请依据下方原始错误核对原因，并先检查仓库历史与本地状态；不要直接重复提交。", rejected: false)
    }

    private static let codePattern = try! NSRegularExpression(pattern: #"\bE[0-9]{6}\b"#)
}

func safeCommitDiagnostic(_ detail: String, password: String) -> String {
    var text = password.isEmpty ? detail : detail.replacingOccurrences(of: password, with: "[已隐藏]")
    for (pattern, replacement) in [
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer [已隐藏]"),
        (#"(?i)((?:password|passwd|token|secret|connectionstring)\s*[:=]\s*)[^\s;]+"#, "$1[已隐藏]"),
        (#"(?i)(https?://)[^/\s:@]+:[^/\s@]+@"#, "$1[已隐藏]@")
    ] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    return String(text.prefix(4_000))
}
