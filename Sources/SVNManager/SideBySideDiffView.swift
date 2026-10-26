import AppKit
import SwiftUI
import SVNCore

struct SideBySideDiffView: NSViewRepresentable {
    let presentation: FileDiffPresentation
    let rowMap: SVNDiffRowMap?
    let mappingID: UUID
    let syntaxColors: Bool
    let focusedRow: Int?
    let jumpID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffPaneContainer {
        let host = DiffPaneContainer()
        context.coordinator.attach(host)
        return host
    }

    func updateNSView(_ host: DiffPaneContainer, context: Context) {
        context.coordinator.update(presentation, rowMap: rowMap, mappingID: mappingID, syntaxColors: syntaxColors,
                                   focusedRow: focusedRow, jumpID: jumpID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffPaneContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1_000, height: proposal.height ?? 400)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var host: DiffPaneContainer?
        private var presentation: FileDiffPresentation?
        private var observers: [NSObjectProtocol] = []
        private var syncing = false
        private var lastJump = -1
        private var rowMap: SVNDiffRowMap?
        private var mappingID: UUID?
        private var syntaxColors = true
        private struct StyleKey: Hashable { let row: Int; let local: Bool }
        private var styleCache: [StyleKey: [SVNCodeToken]] = [:]
        private var cacheOrder: [StyleKey] = []
        private var styleTasks: [StyleKey: Task<Void, Never>] = [:]
        private var stylingGeneration = UUID()

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            styleTasks.values.forEach { $0.cancel() }
        }

        func attach(_ host: DiffPaneContainer) {
            self.host = host
            for (index, scroll) in host.panes.enumerated() {
                let table = scroll.documentView as! DiffLineTable
                table.dataSource = self
                table.delegate = self
                table.copySelected = { [weak self, weak table] in
                    guard let self, let table, let rows = self.presentation?.lines.rows else { return }
                    let text = table.selectedRowIndexes.compactMap { row -> String? in
                        guard let source = self.sourceRow(row), rows.indices.contains(source) else { return nil }
                        return index == 0 ? rows[source].localText : rows[source].remoteText
                    }.joined(separator: "\n")
                    guard !table.selectedRowIndexes.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                scroll.contentView.postsBoundsChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: scroll.contentView, queue: .main) { [weak self] _ in self?.syncScroll(from: index) })
            }
            host.didLayout = { [weak self] in self?.resizeTables() }
        }

        func update(_ value: FileDiffPresentation, rowMap: SVNDiffRowMap?, mappingID: UUID, syntaxColors: Bool,
                    focusedRow: Int?, jumpID: Int) {
            guard let host else { return }
            let changedPresentation = presentation?.id != value.id
            let changedMap = self.mappingID != mappingID
            let changedSyntax = self.syntaxColors != syntaxColors
            if changedPresentation || changedSyntax { stylingGeneration = UUID() }
            if changedPresentation {
                styleTasks.values.forEach { $0.cancel() }; styleTasks = [:]
                styleCache = [:]; cacheOrder = []
            }
            if changedSyntax, !syntaxColors { styleTasks.values.forEach { $0.cancel() }; styleTasks = [:] }
            self.rowMap = rowMap
            self.mappingID = mappingID
            self.syntaxColors = syntaxColors
            if changedPresentation || changedMap || changedSyntax {
                presentation = value
                lastJump = -1
                for (index, scroll) in host.panes.enumerated() {
                    let table = scroll.documentView as! DiffLineTable
                    table.setAccessibilityLabel(index == 0 ? value.files.localLabel + "内容" : value.files.remoteLabel + "内容")
                    table.reloadData()
                    if changedPresentation || changedMap {
                        table.deselectAll(nil)
                        scroll.contentView.scroll(to: .zero)
                    }
                }
                resizeTables()
            }
            if lastJump != jumpID {
                lastJump = jumpID
                if let focusedRow, value.lines.rows.indices.contains(focusedRow), let displayed = displayRow(focusedRow) {
                    for scroll in host.panes {
                        let table = scroll.documentView as! DiffLineTable
                        table.selectRowIndexes(IndexSet(integer: displayed), byExtendingSelection: false)
                        table.scrollRowToVisible(displayed)
                    }
                }
            }
        }

        private func resizeTables() {
            guard let host, let presentation else { return }
            let origin = host.panes[0].contentView.bounds.origin
            let wasSyncing = syncing
            syncing = true
            defer { syncing = wasSyncing }
            // Both panes need the same canvas so the shorter file cannot clamp
            // its horizontal position before the longer file reaches the edge.
            let columns = max(presentation.localColumns, presentation.remoteColumns)
            let width = max(host.panes.map { $0.contentSize.width }.max() ?? 0, CGFloat(columns) * 7.4 + 78)
            for scroll in host.panes {
                let table = scroll.documentView as! DiffLineTable
                if abs(table.tableColumns[0].width - width) > 0.5 { table.tableColumns[0].width = width }
                let size = NSSize(width: width, height: max(scroll.contentSize.height, CGFloat(displayedCount) * table.rowHeight))
                if table.frame.size != size { table.setFrameSize(size) }
                table.needsDisplay = true
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func syncScroll(from index: Int) {
            guard !syncing, let host else { return }
            let source = host.panes[index].contentView
            let otherScroll = host.panes[1 - index]
            let other = otherScroll.contentView
            let origin = source.bounds.origin
            guard abs(origin.x - other.bounds.origin.x) > 0.5 || abs(origin.y - other.bounds.origin.y) > 0.5 else { return }
            syncing = true
            other.scroll(to: origin)
            otherScroll.reflectScrolledClipView(other)
            syncing = false
        }

        private var displayedCount: Int { rowMap?.sourceIndexes.count ?? presentation?.lines.rows.count ?? 0 }
        private func sourceRow(_ displayed: Int) -> Int? {
            guard displayed >= 0, displayed < displayedCount else { return nil }
            return rowMap.map { $0.sourceIndexes[displayed] } ?? displayed
        }
        private func displayRow(_ source: Int) -> Int? {
            if let rowMap { return rowMap.displayIndex(forSource: source) }
            return source >= 0 && source < displayedCount ? source : nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayedCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let host, let presentation, let source = sourceRow(row), presentation.lines.rows.indices.contains(source) else { return nil }
            let isLocal = tableView === host.panes[0].documentView
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("comparison-line"), owner: self) as? DiffLineCell ?? DiffLineCell()
            let key = StyleKey(row: source, local: isLocal)
            cell.configure(presentation.lines.rows[source], local: isLocal, table: tableView, index: row,
                           label: isLocal ? presentation.files.localLabel : presentation.files.remoteLabel,
                           inline: presentation.decorations.inlineChanges[source],
                           tokens: syntaxColors ? styleCache[key] ?? [] : [], gap: rowMap?.gapBefore.contains(row) == true)
            if syntaxColors, styleCache[key] == nil { requestStyle(key, source: presentation.lines.rows[source]) }
            return cell
        }

        private func requestStyle(_ key: StyleKey, source: SVNComparisonRow) {
            guard styleTasks[key] == nil, styleTasks.count < 64, let presentation else { return }
            guard let text = key.local ? source.localText : source.remoteText else { styleCache[key] = []; return }
            let id = presentation.id, language = presentation.language, generation = stylingGeneration
            // Rendering/cache mutations stay on the main actor; the lexer alone
            // runs detached and returns value-only ranges for the visible row.
            styleTasks[key] = Task { @MainActor [weak self] in
                let worker = Task.detached(priority: .utility) { try SVNCodeStyling.tokens(in: text, language: language) }
                do {
                    let tokens = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard let self, !Task.isCancelled, self.presentation?.id == id,
                          self.stylingGeneration == generation, self.syntaxColors else { return }
                    self.styleTasks[key] = nil
                    self.styleCache[key] = tokens; self.cacheOrder.append(key)
                    if self.cacheOrder.count > 1_000 { self.styleCache[self.cacheOrder.removeFirst()] = nil }
                    guard let displayed = self.displayRow(key.row), let host = self.host else { return }
                    let table = host.panes[key.local ? 0 : 1].documentView as! DiffLineTable
                    if table.rows(in: table.visibleRect).contains(displayed) {
                        table.reloadData(forRowIndexes: IndexSet(integer: displayed), columnIndexes: IndexSet(integer: 0))
                    }
                } catch {
                    if self?.presentation?.id == id, self?.stylingGeneration == generation { self?.styleTasks[key] = nil }
                }
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            table.enumerateAvailableRowViews { view, _ in
                view.subviews.forEach { $0.needsDisplay = true }
            }
        }
    }
}

final class DiffPaneContainer: NSView {
    let panes: [NSScrollView] = [NSScrollView(), NSScrollView()]
    var didLayout: (() -> Void)?
    private let divider = NSBox()
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        divider.boxType = .separator
        addSubview(divider)
        for pane in panes {
            pane.hasVerticalScroller = true
            pane.hasHorizontalScroller = true
            pane.autohidesScrollers = false
            pane.horizontalScrollElasticity = .none
            pane.verticalScrollElasticity = .none
            pane.backgroundColor = .textBackgroundColor
            pane.borderType = .noBorder
            let table = DiffLineTable()
            table.headerView = nil
            table.rowHeight = 22
            table.intercellSpacing = .zero
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.selectionHighlightStyle = .none
            table.allowsMultipleSelection = true
            table.backgroundColor = .textBackgroundColor
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("code"))
            column.minWidth = 40
            column.maxWidth = 200_000
            table.addTableColumn(column)
            pane.documentView = table
            addSubview(pane)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        let width = max(0, (bounds.width - 1) / 2)
        panes[0].frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        panes[1].frame = NSRect(x: width + 1, y: 0, width: width, height: bounds.height)
        divider.frame = NSRect(x: width, y: 0, width: 1, height: bounds.height)
        panes.forEach { $0.tile() }
        didLayout?()
    }
}

private final class DiffLineTable: NSTableView {
    var copySelected: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let actions = NSMenu()
        let item = NSMenuItem(title: "复制选中行", action: #selector(copyLines), keyEquivalent: "")
        item.target = self
        actions.addItem(item)
        menu = actions
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func copyLines() { copySelected?() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { copySelected?() }
        else { super.keyDown(with: event) }
    }
}

private final class DiffLineCell: NSView {
    private let number = NSTextField(labelWithString: "")
    private let marker = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private var change: SVNLineChange = .unchanged
    private var hasText = true
    private weak var table: NSTableView?
    private var row = 0
    private var gap = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("comparison-line")
        for label in [number, marker, code] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byClipping
            addSubview(label)
            label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        number.alignment = .right
        number.textColor = .secondaryLabelColor
        code.textColor = .textColor
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5), marker.widthAnchor.constraint(equalToConstant: 15),
            number.leadingAnchor.constraint(equalTo: marker.trailingAnchor), number.widthAnchor.constraint(equalToConstant: 38),
            code.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 12),
            code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
        code.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ value: SVNComparisonRow, local: Bool, table: NSTableView, index: Int, label: String,
                   inline: SVNInlineChanges?, tokens: [SVNCodeToken], gap: Bool) {
        self.table = table
        row = index
        self.gap = gap
        change = value.change
        let text = local ? value.localText : value.remoteText
        let lineNumber = local ? value.localNumber : value.remoteNumber
        hasText = text != nil
        number.stringValue = lineNumber.map(String.init) ?? ""
        var prefix = Array((text ?? "").utf16.prefix(8_193))
        let truncated = prefix.count > 8_192
        if truncated { prefix.removeLast() }
        if let last = prefix.last, (0xD800...0xDBFF).contains(last) { prefix.removeLast() }
        let display = String(decoding: prefix, as: UTF16.self) + (truncated ? " …" : "")
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 28.8
        let attributed = NSMutableAttributedString(string: display, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor, .paragraphStyle: style
        ])
        for token in tokens {
            let color: NSColor
            switch token.kind {
            case .keyword: color = .systemPurple
            case .string: color = .systemRed
            case .number: color = .systemBlue
            case .comment: color = .systemGreen
            case .directive: color = .systemOrange
            case .tag: color = .systemIndigo
            }
            let range = NSIntersectionRange(token.range, NSRange(location: 0, length: prefix.count))
            if range.length > 0 { attributed.addAttribute(.foregroundColor, value: color, range: range) }
        }
        for change in (local ? inline?.local : inline?.remote) ?? [] {
            let range = NSIntersectionRange(change, NSRange(location: 0, length: prefix.count))
            if range.length > 0 {
                attributed.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.38), range: range)
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        code.attributedStringValue = attributed
        toolTip = truncated ? "该行较长，已限制单行显示；可复制全文查看完整内容。" : nil
        marker.stringValue = hasText ? (change == .added ? "+" : change == .deleted ? "−" : change == .modified ? "↔" : "") : ""
        marker.textColor = tint ?? .secondaryLabelColor
        let status = change == .added ? "新增" : change == .deleted ? "删除" : change == .modified ? "修改" : "未变"
        setAccessibilityLabel("\(label)\(lineNumber.map { "第\($0)行" } ?? "对齐空位")，\(status)\(gap ? "，之前内容已折叠" : "")")
        needsDisplay = true
    }

    private var tint: NSColor? {
        switch change {
        case .added: return .systemGreen
        case .deleted: return .systemRed
        case .modified: return .systemOrange
        case .unchanged: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !hasText {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(rect: dirtyRect).fill()
        } else if let tint {
            tint.withAlphaComponent(0.14).setFill()
            NSBezierPath(rect: dirtyRect).fill()
        }
        if table?.isRowSelected(row) == true {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: dirtyRect).fill()
        }
        if gap {
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1)).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
