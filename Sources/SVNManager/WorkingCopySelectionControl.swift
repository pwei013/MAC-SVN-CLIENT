import AppKit
import SwiftUI

/// One stable header control reuses the existing visible-selection operations.
struct WorkingCopySelectionControl: View {
    @ObservedObject var model: AppModel

    private var allChecked: Bool {
        !model.changeFilterResult.checkablePaths.isEmpty && model.changeFilterResult.checkablePaths.isSubset(of: model.checkedPaths)
    }
    private var checkboxState: NSControl.StateValue {
        if allChecked { return .on }
        return model.checkedPaths.isDisjoint(with: model.changeFilterResult.checkablePaths) ? .off : .mixed
    }

    var body: some View {
        HStack(spacing: 4) {
            VisibleSelectionCheckbox(state: checkboxState,
                isEnabled: !model.busy && !model.isFilteringChanges && !model.changeFilterResult.checkablePaths.isEmpty) {
                    if allChecked { model.uncheckVisibleChanges() }
                    else { model.checkAllVisibleChanges() }
                }.frame(width: 18, height: 18)
            Menu {
                Button("全选当前结果", action: model.checkAllVisibleChanges)
                    .disabled(model.changeFilterResult.checkablePaths.isSubset(of: model.checkedPaths))
                Button("勾选可提交项", action: model.checkVisibleCommittableChanges)
                    .help("勾选当前结果中可直接提交或自动 Add 后提交的项目，保留其他勾选")
                Button("取消当前结果勾选", action: model.uncheckVisibleChanges)
                    .disabled(model.checkedPaths.isDisjoint(with: model.changeFilterResult.visiblePaths))
                Divider()
                Button("清空全部勾选") { model.checkedPaths = [] }.disabled(model.checkedPaths.isEmpty)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 20)
                    .accessibilityHidden(true)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("文件选择菜单").help("全选、勾选可提交项或清空勾选")
                .disabled(model.busy || model.isFilteringChanges)
        }.frame(width: 44, height: 24)
    }
}

private struct VisibleSelectionCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let isEnabled: Bool
    let toggle: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(toggle) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        button.setAccessibilityLabel("全选当前结果")
        button.toolTip = "勾选或取消当前结果，保留其他筛选下的勾选"
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        button.state = state
        button.isEnabled = isEnabled
    }
    final class Coordinator: NSObject {
        var toggle: () -> Void
        init(_ toggle: @escaping () -> Void) { self.toggle = toggle }
        @objc func clicked() { toggle() }
    }
}
