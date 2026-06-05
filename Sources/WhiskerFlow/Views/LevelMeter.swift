import SwiftUI

/// A compact animated bar meter that reacts to a 0...1 input level.
struct LevelMeter: View {
    var level: Float
    var barCount: Int = 5
    var tint: Color = .accentColor
    var minHeight: CGFloat = 4
    var maxHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        // Emphasize the center bars so quiet speech still looks alive.
        let mid = Double(barCount - 1) / 2
        let distance = abs(Double(index) - mid)
        let weight = 1.0 - (distance / (mid + 1)) * 0.6
        let scaled = CGFloat(Double(level) * weight)
        return minHeight + (maxHeight - minHeight) * min(1, max(0.05, scaled))
    }
}

#Preview {
    LevelMeter(level: 0.7)
        .padding()
}
