import AppKit
import SwiftUI

/// AppKit lays out visible text as it scrolls, so a large diff does not require
/// SwiftUI to measure one giant Text view before showing the window.
struct DiffTextView: NSViewRepresentable {
    let text: String
    let findRequest: Int

    final class Coordinator {
        var displayed: String?
        var findRequest = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.findBarPosition = .aboveContent
        scroll.borderType = .noBorder
        scroll.backgroundColor = .textBackgroundColor
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.usesFindBar = true
        view.setAccessibilityLabel("文件差异内容")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if context.coordinator.displayed != text {
            context.coordinator.displayed = text
            view.string = text
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.window?.makeFirstResponder(view)
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            view.performFindPanelAction(item)
        }
    }
}
