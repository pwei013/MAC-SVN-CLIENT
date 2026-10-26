import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SVNCore

private enum FileIconType: String {
    case folder, symbolicLink, source, project, json, configuration, markdown, text, document, pdf
    case image, audio, video, archive, application, library, database, spreadsheet, presentation, web, script, font, file

    static func classify(path: String, kind: WorkingCopyNodeKind) -> Self {
        if kind == .directory { return .folder }
        if kind == .symbolicLink { return .symbolicLink }
        let name = (path as NSString).lastPathComponent.lowercased()
        if [".gitignore", ".svnignore", ".editorconfig", ".gitattributes", ".npmrc", ".env"].contains(name) || name.hasPrefix(".env.") { return .configuration }
        if ["makefile", "dockerfile", "gemfile", ".bashrc", ".zshrc", ".bash_profile", ".zprofile"].contains(name) { return .script }
        switch (name as NSString).pathExtension {
        case "cs", "fs", "vb", "swift", "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "go", "rs", "py", "r", "dart", "lua", "scala", "js", "jsx", "ts", "tsx", "cjs", "mjs", "vue", "svelte", "razor", "cshtml": return .source
        case "csproj", "fsproj", "vbproj", "vcxproj", "sln", "slnx", "xcodeproj", "xcworkspace", "pbxproj", "gradle", "sbt": return .project
        case "json", "jsonc", "json5", "geojson": return .json
        case "xml", "config", "ini", "yaml", "yml", "toml", "properties", "settings", "props", "targets", "env": return .configuration
        case "md", "markdown", "mdown", "rst": return .markdown
        case "txt", "log": return .text
        case "doc", "docx", "rtf", "odt", "pages": return .document
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "icns", "ico", "svg": return .image
        case "mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff": return .audio
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return .video
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "zst": return .archive
        case "exe", "app", "dmg", "pkg", "msi": return .application
        case "dll", "so", "dylib", "a", "lib", "pdb": return .library
        case "sql", "db", "sqlite", "sqlite3", "mdb", "bak": return .database
        case "xls", "xlsx", "xlsm", "csv", "tsv", "ods", "numbers": return .spreadsheet
        case "ppt", "pptx", "odp", "key": return .presentation
        case "html", "htm", "css", "scss", "sass", "less", "wasm": return .web
        case "sh", "bash", "zsh", "ps1", "bat", "cmd": return .script
        case "ttf", "otf", "woff", "woff2": return .font
        default: return .file
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .symbolicLink: return "link"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .project: return "square.stack.3d.up.fill"
        case .json: return "curlybraces"
        case .configuration: return "gearshape.fill"
        case .markdown, .document, .pdf: return "doc.richtext"
        case .text, .file: return "doc.text"
        case .image: return "photo.fill"
        case .audio: return "waveform"
        case .video: return "film.fill"
        case .archive: return "archivebox.fill"
        case .application: return "app.fill"
        case .library: return "shippingbox.fill"
        case .database: return "externaldrive.fill"
        case .spreadsheet: return "tablecells.fill"
        case .presentation: return "rectangle.on.rectangle"
        case .web: return "globe"
        case .script: return "terminal.fill"
        case .font: return "textformat"
        }
    }

    var color: Color {
        switch self {
        case .folder, .project: return .indigo
        case .symbolicLink, .markdown, .font: return .teal
        case .source, .document, .application, .web: return .blue
        case .json, .configuration, .archive, .presentation: return .orange
        case .pdf, .database: return .red
        case .image, .spreadsheet: return .green
        case .audio, .video: return .purple
        case .script, .library, .text, .file: return .secondary
        }
    }

    var label: String {
        switch self {
        case .folder: return "文件夹"
        case .symbolicLink: return "符号链接"
        case .source: return "代码文件"
        case .project: return "项目文件"
        case .json: return "JSON 文件"
        case .configuration: return "配置文件"
        case .markdown: return "Markdown 文档"
        case .text: return "文本文件"
        case .document: return "文档"
        case .pdf: return "PDF 文档"
        case .image: return "图片"
        case .audio: return "音频"
        case .video: return "视频"
        case .archive: return "压缩文件"
        case .application: return "应用程序"
        case .library: return "库或调试文件"
        case .database: return "数据库文件"
        case .spreadsheet: return "电子表格"
        case .presentation: return "演示文稿"
        case .web: return "网页文件"
        case .script: return "脚本文件"
        case .font: return "字体文件"
        case .file: return "文件"
        }
    }
}

/// Cache by category/extension, never by row selection or by the full local path.
/// Rendering an icon performs no filesystem reads or SVN commands.
@MainActor
private final class FileIconCache {
    static let shared = FileIconCache()
    private let images = NSCache<NSString, NSImage>()

    private init() { images.countLimit = 128 }

    func image(for type: FileIconType, extension suffix: String) -> NSImage {
        let key = (type == .file ? "file:" + suffix : type.rawValue) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let icon: NSImage
        if type == .file, !suffix.isEmpty, let contentType = UTType(filenameExtension: suffix) {
            icon = NSWorkspace.shared.icon(for: contentType)
        } else {
            icon = NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!
            icon.isTemplate = true
        }
        images.setObject(icon, forKey: key)
        return icon
    }
}

struct FileTypeIcon: View {
    let path: String
    let kind: WorkingCopyNodeKind

    var body: some View {
        let type = FileIconType.classify(path: path, kind: kind)
        let suffix = (path as NSString).pathExtension.lowercased()
        let label = type.label + (suffix.isEmpty || type == .folder || type == .symbolicLink ? "" : "（\(suffix.uppercased())）")
        Image(nsImage: FileIconCache.shared.image(for: type, extension: suffix))
            .resizable().scaledToFit().foregroundStyle(type.color)
            .frame(width: 18, height: 18)
            .accessibilityLabel(label).help(label)
            .allowsHitTesting(false)
    }
}
