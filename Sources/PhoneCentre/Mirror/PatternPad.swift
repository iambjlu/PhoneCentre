import SwiftUI

/// 3×3 圖形密碼輸入：拖曳經過圓點，點的編號 1–9（左上到右下）
struct PatternPad: View {
    @Binding var sequence: [Int]
    var size: CGFloat = 180
    @State private var current: CGPoint?

    private func center(_ n: Int) -> CGPoint {
        let cell = size / 3
        return CGPoint(x: cell * (CGFloat((n - 1) % 3) + 0.5), y: cell * (CGFloat((n - 1) / 3) + 0.5))
    }

    private func hit(_ p: CGPoint) -> Int? {
        (1...9).first { hypot(center($0).x - p.x, center($0).y - p.y) < size / 9 }
    }

    var body: some View {
        ZStack {
            Path { path in
                for (i, n) in sequence.enumerated() {
                    i == 0 ? path.move(to: center(n)) : path.addLine(to: center(n))
                }
                if let current, !sequence.isEmpty { path.addLine(to: current) }
            }
            .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ForEach(1...9, id: \.self) { n in
                Circle()
                    .fill(sequence.contains(n) ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: sequence.contains(n) ? 16 : 12, height: sequence.contains(n) ? 16 : 12)
                    .position(center(n))
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if v.translation == .zero, v.startLocation == v.location { sequence = [] }
                current = v.location
                if let n = hit(v.location), !sequence.contains(n) { sequence.append(n) }
            }
            .onEnded { _ in current = nil })
    }
}
