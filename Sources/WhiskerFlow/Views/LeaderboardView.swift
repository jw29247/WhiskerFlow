import SwiftUI
import WhiskerFlowCore

/// Everyone at the company who uses WhiskerFlow, from Atlas.
struct LeaderboardView: View {
    @Bindable var appState: AppState

    private var leaderboard: LeaderboardController { appState.leaderboard }

    var body: some View {
        @Bindable var leaderboard = leaderboard
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Leaderboard").font(.system(size: 24, weight: .semibold, design: .rounded))
                Spacer()
                Picker("Period", selection: $leaderboard.window) {
                    ForEach(LeaderboardWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { Task { await leaderboard.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(leaderboard.isLoading)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .padding(.horizontal, 28).padding(.vertical, 25)
            Divider()
            Picker("Rank by", selection: $leaderboard.metric) {
                ForEach(LeaderboardMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 28).padding(.vertical, 14)
            content
            footer
        }
        .task { await leaderboard.refresh() }
    }

    @ViewBuilder private var content: some View {
        let rows = leaderboard.rows
        if let message = leaderboard.errorMessage, leaderboard.board == nil {
            FlowEmptyState(symbol: "trophy", title: "The leaderboard isn't available.", detail: message)
        } else if leaderboard.board == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            FlowEmptyState(symbol: "trophy", title: "Nobody's on the board yet.",
                           detail: "Dictate anywhere and you'll appear here for the whole team.")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(rows) { row in
                        LeaderboardRowView(row: row, metric: leaderboard.metric)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 8)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Shared with colleagues in Atlas: your name and daily counts. Never any text.", systemImage: "lock")
            Spacer()
            if let message = leaderboard.errorMessage, leaderboard.board != nil {
                Text(message).foregroundStyle(.orange)
            } else if let updated = leaderboard.updatedAt {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
        .padding(.horizontal, 28).padding(.vertical, 12)
    }
}

private struct LeaderboardRowView: View {
    let row: LeaderboardRanking.Row
    let metric: LeaderboardMetric

    private var entry: LeaderboardEntry { row.entry }

    var body: some View {
        HStack(spacing: 14) {
            rank.frame(width: 34)
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 14, weight: .medium))
                    if entry.isYou {
                        Text("You").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(FlowStyle.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(FlowStyle.accent)
                    }
                }
                Text(secondary).font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
            }
            Spacer()
            Text(primary)
                .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(entry.isYou ? FlowStyle.selection : FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(FlowStyle.line))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var rank: some View {
        switch row.rank {
        case 1...3:
            Image(systemName: "medal.fill")
                .foregroundStyle([Color.yellow, Color.gray, Color.orange][row.rank - 1])
                .font(.system(size: 18))
                .accessibilityLabel("Rank \(row.rank)")
        default:
            Text("\(row.rank)").font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(FlowStyle.muted)
        }
    }

    private var avatar: some View {
        let initials = entry.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return ZStack {
            Circle().fill(FlowStyle.accent.opacity(0.15))
            if let url = entry.avatarUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Text(initials) }
                    .clipShape(Circle())
            } else {
                Text(initials).font(.system(size: 12, weight: .semibold)).foregroundStyle(FlowStyle.accent)
            }
        }
        .frame(width: 32, height: 32)
    }

    private var primary: String {
        switch metric {
        case .words: return entry.words.formatted()
        case .timeSaved: return InsightsView.duration(Double(entry.timeSavedSeconds))
        case .streak: return entry.currentStreakDays == 1 ? "1 day" : "\(entry.currentStreakDays) days"
        case .meetings: return entry.meetings.formatted()
        }
    }

    private var secondary: String {
        var parts: [String] = []
        if metric != .words { parts.append("\(entry.words.formatted()) words") }
        if metric != .timeSaved { parts.append("\(InsightsView.duration(Double(entry.timeSavedSeconds))) saved") }
        if metric != .streak, entry.currentStreakDays > 0 { parts.append("\(entry.currentStreakDays)-day streak") }
        if metric == .streak, entry.longestStreakDays > entry.currentStreakDays { parts.append("best \(entry.longestStreakDays) days") }
        if metric == .meetings {
            parts.append(InsightsView.duration(Double(entry.meetingSeconds)) + " recorded")
        } else if entry.meetings > 0 {
            parts.append(entry.meetings == 1 ? "1 meeting" : "\(entry.meetings) meetings")
        }
        return parts.joined(separator: " · ")
    }
}
