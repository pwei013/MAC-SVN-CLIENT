import SwiftUI

struct RecentLocationRow<LabelContent: View>: View {
    let pinned: Bool
    let isSelected: Bool
    let isBusy: Bool
    let name: String
    let detail: String
    let open: () -> Void
    let togglePin: () -> Void
    let remove: () -> Void
    @ViewBuilder let label: () -> LabelContent
    @State private var isHovered = false

    private var showsActions: Bool { isHovered || isSelected }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: open) {
                label()
                    .fontWeight(isSelected ? .semibold : .regular)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(detail)
                .foregroundStyle(isSelected ? Color.indigo : Color.primary)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            HStack(spacing: 0) {
                Button(action: togglePin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? Color.indigo : Color.secondary)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }.help(pinned ? "取消固定到顶部" : "固定到顶部")
                    .accessibilityLabel((pinned ? "取消固定：" : "固定到顶部：") + name)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }.help("从最近列表移除；保留磁盘文件、仓库账号和项目草稿")
                    .accessibilityLabel("从最近列表移除：" + name)
            }.buttonStyle(.plain).font(.system(size: 11))
                // Keep action space stable so names never shift as the pointer moves.
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
                .accessibilityHidden(!showsActions)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(isSelected ? Color.indigo.opacity(0.14) : isHovered ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Color.indigo.opacity(0.24) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .disabled(isBusy)
        .contextMenu {
            Button(pinned ? "取消固定到顶部" : "固定到顶部", systemImage: pinned ? "pin.slash" : "pin", action: togglePin)
            Divider()
            Button("从最近列表移除", systemImage: "trash", role: .destructive, action: remove)
                .help("仅移除这条记录，保留本地文件、仓库账号和项目草稿")
        }
    }
}
