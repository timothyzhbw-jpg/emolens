import AppKit
import SwiftUI

/// 圆形图标按钮，悬停时显示底色。
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 胶囊形按钮，用于次要操作。
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(filled ? Color.white : tint)
            .background(Capsule().fill(tint.opacity(filled ? (configuration.isPressed ? 0.8 : 1) : (configuration.isPressed ? 0.22 : 0.13))))
            .contentShape(Capsule())
    }
}

/// 状态指示灯；active 时缓慢呼吸。
struct PulseDot: View {
    let color: Color
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle().fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1 : 0.4)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// 纯 SwiftUI 的加载动画（系统 ProgressView 在预览渲染里画不出来）。
struct Spinner: View {
    var size: CGFloat = 12
    @State private var spinning = false

    var body: some View {
        Circle().trim(from: 0.1, to: 0.8)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true } }
    }
}

/// 自动换行排列子视图（信号标签用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// 小节标题：图标 + 文字 + 可选的右侧内容。
struct SectionTitle<Trailing: View>: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(symbol: String, title: String, tint: Color = .secondary) {
        self.init(symbol: symbol, title: title, tint: tint) { EmptyView() }
    }
}

/// 复制按钮，点击后短暂显示「已复制」。
struct CopyButton: View {
    let text: String
    var tint: Color = Theme.reply
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
        } label: {
            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PillButtonStyle(tint: tint, filled: copied))
    }
}

/// 细分隔线（系统 Divider 在预览渲染里画不出来）。
struct Hairline: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
}
