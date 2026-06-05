import SwiftUI
import WhiskerFlowCore

struct StatsView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Dictation Stats")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            VStack(spacing: 10) {
                StatRow(title: "All time", stats: appState.analytics.allTime)
                Divider()
                StatRow(title: "This week", stats: appState.analytics.thisWeek)
                Divider()
                StatRow(title: "Last 30 days", stats: appState.analytics.lastMonth)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))

            Text("Last 14 days")
                .font(.headline)
            MiniBarChart(data: appState.dailyWordCounts)
                .frame(height: 140)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 480, height: 460)
    }
}

private struct StatRow: View {
    let title: String
    let stats: TranscriptStats

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(stats.wordCount) words").monospacedDigit()
                Text("\(formattedMinutes) typing saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var formattedMinutes: String {
        let minutes = stats.estimatedTypingMinutes()
        if minutes < 1, stats.wordCount > 0 { return "<1 min" }
        return "\(Int(minutes.rounded())) min"
    }
}

private struct MiniBarChart: View {
    let data: [DailyWordCount]

    var body: some View {
        let maxValue = max(1, data.map(\.words).max() ?? 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(data) { point in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(point.words > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(height: barHeight(point.words, max: maxValue, available: geo.size.height - 18))
                        Text(point.day, format: .dateTime.day())
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func barHeight(_ value: Int, max maxValue: Int, available: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 2 }
        return max(2, available * CGFloat(value) / CGFloat(maxValue))
    }
}
