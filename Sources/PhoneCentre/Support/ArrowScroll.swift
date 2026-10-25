import SwiftUI

/// 內容放不下時，在可捲動的那一端出現小箭頭，按下去往那個方向捲動一頁（捲軸隱藏）
struct ArrowScroll<Content: View>: View {
    let axis: Axis
    @ViewBuilder let content: () -> Content

    private struct Info: Equatable { var offset: CGFloat = 0; var content: CGFloat = 0; var visible: CGFloat = 0 }

    @State private var position = ScrollPosition()
    @State private var info = Info()

    private var horizontal: Bool { axis == .horizontal }
    private var canBack: Bool { info.offset > 1 }
    private var canForward: Bool { info.offset + info.visible < info.content - 1 }

    var body: some View {
        ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) { content() }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Info.self) { g in
                horizontal
                    ? Info(offset: g.contentOffset.x, content: g.contentSize.width, visible: g.visibleRect.width)
                    : Info(offset: g.contentOffset.y, content: g.contentSize.height, visible: g.visibleRect.height)
            } action: { _, new in info = new }
            .overlay(alignment: horizontal ? .leading : .top) { if canBack { arrow(forward: false) } }
            .overlay(alignment: horizontal ? .trailing : .bottom) { if canForward { arrow(forward: true) } }
    }

    private func arrow(forward: Bool) -> some View {
        Button {
            let page = max(info.visible * 0.8, 40)
            let target = forward ? min(info.offset + page, info.content - info.visible) : max(info.offset - page, 0)
            withAnimation(.easeInOut(duration: 0.25)) {
                if horizontal { position.scrollTo(x: target) } else { position.scrollTo(y: target) }
            }
        } label: {
            // 只用 chevron.compact.backward（朝左）一個符號，轉出四個方向：左 0°、上 90°、右 180°、下 270°
            Image(systemName: "chevron.compact.backward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(horizontal ? (forward ? 180 : 0) : (forward ? 270 : 90)))
                .frame(width: horizontal ? 24 : 30, height: horizontal ? 30 : 18)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(horizontal ? .horizontal : .vertical, 2)
        .help(forward ? "往後捲動" : "往前捲動")
    }
}

/// 內容多長就多長（不撐滿可用空間），放不下才縮短並出現箭頭可以捲動
struct FitScroll<Content: View>: View {
    let axis: Axis
    @ViewBuilder let content: () -> Content
    @State private var length: CGFloat = 0

    var body: some View {
        ArrowScroll(axis: axis) {
            content().background(GeometryReader { g in
                Color.clear.preference(key: FitScrollLengthKey.self, value: axis == .horizontal ? g.size.width : g.size.height)
            })
        }
        .onPreferenceChange(FitScrollLengthKey.self) { length = $0 }
        .frame(maxWidth: axis == .horizontal && length > 0 ? length : nil,
               maxHeight: axis == .vertical && length > 0 ? length : nil)
    }
}

private struct FitScrollLengthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
