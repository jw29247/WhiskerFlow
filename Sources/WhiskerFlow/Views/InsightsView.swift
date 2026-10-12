import AppKit
import SwiftUI
import WhiskerFlowCore

/// Lifetime dictation Insights. Everything here comes from the aggregate store,
/// so it survives any history-retention setting.
struct InsightsView: View {
    @Bindable var appState: AppState
    @State private var confirmReset = false

    private var summary: InsightsSummary { appState.insightsSummary }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Insights").font(.system(size: 24, weight: .semibold, design: .rounded))
                Spacer()
                Button { confirmReset = true } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                    .disabled(summary.isEmpty)
                    .help("Reset insights")
            }
            .padding(.horizontal, 28).padding(.vertical, 25)
            Divider()
            if summary.isEmpty {
                FlowEmptyState(symbol: "chart.bar.xaxis", title: "Your insights start here.",
                               detail: "Dictate anywhere and your words, speaking speed and streaks will appear here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 16) {
                            InsightTile(title: "Lifetime words", value: summary.lifetimeWords.formatted(),
                                        detail: dictationCount(summary.lifetimeDictations))
                            InsightTile(title: "This week", value: summary.wordsThisWeek.formatted(), detail: "words")
                            InsightTile(title: "This month", value: summary.wordsThisMonth.formatted(), detail: "words")
                        }
                        HStack(alignment: .top, spacing: 16) {
                            speedCard
                            streakCard.frame(width: 250)
                        }
                        heatmapCard
                        HStack(alignment: .top, spacing: 16) {
                            topAppsCard
                            correctionsCard.frame(width: 250)
                        }
                        Label("Insights are counts only — no transcript text — and stay on this Mac.",
                              systemImage: "lock")
                            .font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
                    }
                    .padding(28)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .alert("Reset insights?", isPresented: $confirmReset) {
            Button("Reset insights", role: .destructive) { appState.resetInsights() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your word counts, speed, streaks and activity start again from zero. History is not affected.")
        }
    }

    // MARK: - Cards

    private var speedCard: some View {
        InsightCard(title: "Speaking vs typing") {
            let speaking = summary.speakingWordsPerMinute
            let typing = Double(summary.typingWordsPerMinute)
            let scale = max(speaking ?? 0, typing, 1)
            VStack(alignment: .leading, spacing: 14) {
                SpeedBar(label: "You speak", value: speaking, scale: scale, color: FlowStyle.accent,
                         caption: speaking == nil ? "Dictate a little more to measure" : "last \(min(summary.lifetimeDictations, InsightsSummary.speakingSampleLimit)) dictations")
                HStack(alignment: .center, spacing: 12) {
                    SpeedBar(label: "You type", value: typing, scale: scale, color: FlowStyle.muted.opacity(0.55),
                             caption: "your setting")
                    Stepper("Typing speed", value: Binding(get: { appState.settings.typingWordsPerMinute },
                                                           set: { appState.setTypingSpeed($0) }),
                            in: InsightsSummary.typingWordsPerMinuteRange, step: 5)
                        .labelsHidden()
                        .help("Set your typing speed")
                        .accessibilityLabel("Typing speed, \(summary.typingWordsPerMinute) words per minute")
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Time saved").font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
                    Spacer()
                    Text(Self.duration(summary.timeSavedSeconds))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .help("Lifetime words at your typing speed, minus the same words at your speaking speed")
            }
        }
    }

    private var streakCard: some View {
        InsightCard(title: "Streak") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "flame.fill").foregroundStyle(summary.currentStreak > 0 ? FlowStyle.accent : FlowStyle.muted)
                    Text(summary.currentStreak.formatted())
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(summary.currentStreak == 1 ? "day" : "days").foregroundStyle(FlowStyle.muted)
                }
                .accessibilityElement(children: .combine)
                Text("Current streak").font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
                Divider()
                HStack {
                    Text("Longest").font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
                    Spacer()
                    Text(summary.longestStreak == 1 ? "1 day" : "\(summary.longestStreak.formatted()) days")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
            }
        }
    }

    private var heatmapCard: some View {
        InsightCard(title: "When you dictate") {
            ActivityHeatmapView(heatmap: summary.heatmap)
        }
    }

    private var topAppsCard: some View {
        InsightCard(title: "Top apps") {
            let maximum = max(summary.topApps.first?.words ?? 1, 1)
            VStack(spacing: 12) {
                ForEach(summary.topApps) { usage in
                    AppUsageRow(usage: usage, maximum: maximum)
                }
            }
        }
    }

    private var correctionsCard: some View {
        InsightCard(title: "Corrections applied") {
            VStack(alignment: .leading, spacing: 14) {
                Text(summary.correctionsApplied.formatted())
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                VStack(spacing: 8) {
                    correctionRow("Vocabulary replacements", summary.vocabularyReplacements)
                    correctionRow("Spoken self-corrections", summary.selfCorrections)
                }
            }
        }
    }

    private func correctionRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
            Spacer()
            Text(value.formatted()).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func dictationCount(_ count: Int) -> String {
        count == 1 ? "from 1 dictation" : "from \(count.formatted()) dictations"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds > 0, minutes == 0 { return "< 1 min" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}

// MARK: - Pieces

private struct InsightCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 13, weight: .medium))
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line.opacity(0.6), lineWidth: 1))
    }
}

private struct InsightTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct SpeedBar: View {
    let label: String
    let value: Double?
    let scale: Double
    let color: Color
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(FlowStyle.muted)
                Spacer()
                Text(value.map { "\(Int($0.rounded())) wpm" } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(FlowStyle.line.opacity(0.5))
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat((value ?? 0) / scale)))
                        .opacity(value == nil ? 0 : 1)
                }
            }
            .frame(height: 8)
            Text(caption).font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value.map { "\(Int($0.rounded())) words per minute" } ?? "not measured yet")")
    }
}

/// Weekday × hour grid on a single-hue ramp (the accent, in five steps), with
/// empty hours in the neutral line colour and a Less → More key.
private struct ActivityHeatmapView: View {
    let heatmap: ActivityHeatmap
    private static let steps: [Double] = [0.32, 0.5, 0.66, 0.83, 1]
    private let spacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let labelWidth: CGFloat = 34
                let cell = max(8, (geo.size.width - labelWidth - spacing * 24) / 24)
                let rowHeight = min(cell, 20)
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(heatmap.weekdays.enumerated()), id: \.offset) { row, weekday in
                        HStack(spacing: spacing) {
                            Text(Self.weekdayName(weekday)).font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
                                .frame(width: labelWidth, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                let count = heatmap.counts[row][hour]
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(fill(count))
                                    .frame(width: cell, height: rowHeight)
                                    .help("\(Self.weekdayName(weekday, full: true)) \(Self.hourName(hour)): \(count == 1 ? "1 dictation" : "\(count) dictations")")
                            }
                        }
                    }
                    HStack(spacing: spacing) {
                        Spacer().frame(width: labelWidth)
                        ForEach(0..<24, id: \.self) { hour in
                            Text(hour % 6 == 0 ? Self.hourName(hour) : "")
                                .font(.system(size: 9)).foregroundStyle(FlowStyle.muted)
                                .fixedSize()
                                .frame(width: cell, alignment: .leading)
                        }
                    }
                }
            }
            .frame(height: 7 * 20 + 7 * spacing + 16)
            HStack(spacing: 4) {
                Spacer()
                Text("Less").font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
                RoundedRectangle(cornerRadius: 2).fill(FlowStyle.line.opacity(0.45)).frame(width: 10, height: 10)
                ForEach(Self.steps, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2).fill(FlowStyle.accent.opacity(step)).frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func fill(_ count: Int) -> Color {
        guard count > 0, heatmap.maximum > 0 else { return FlowStyle.line.opacity(0.45) }
        let fraction = Double(count) / Double(heatmap.maximum)
        let index = min(Self.steps.count - 1, Int((fraction * Double(Self.steps.count)).rounded(.up)) - 1)
        return FlowStyle.accent.opacity(Self.steps[max(0, index)])
    }

    private var accessibilitySummary: String {
        var best: (row: Int, hour: Int, count: Int) = (0, 0, 0)
        for (row, hours) in heatmap.counts.enumerated() {
            for (hour, count) in hours.enumerated() where count > best.count { best = (row, hour, count) }
        }
        guard best.count > 0 else { return "No dictation activity yet" }
        return "Activity by day and hour. Busiest: \(Self.weekdayName(heatmap.weekdays[best.row], full: true)) at \(Self.hourName(best.hour))."
    }

    static func weekdayName(_ weekday: Int, full: Bool = false) -> String {
        let symbols = full ? Calendar.current.weekdaySymbols : Calendar.current.shortWeekdaySymbols
        return symbols[(weekday - 1) % symbols.count]
    }

    static func hourName(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        guard let date = Calendar.current.date(from: components) else { return "\(hour)" }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

private struct AppUsageRow: View {
    let usage: AppUsage
    let maximum: Int

    var body: some View {
        let identity = InsightsAppIdentity.resolve(usage.group)
        HStack(spacing: 10) {
            Group {
                if let icon = identity.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "square.dashed").foregroundStyle(FlowStyle.muted)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(identity.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text("\(usage.words.formatted()) words").font(.system(size: 11)).foregroundStyle(FlowStyle.muted)
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    Capsule().fill(FlowStyle.accent)
                        .frame(width: max(4, geo.size.width * CGFloat(usage.words) / CGFloat(maximum)))
                }
                .frame(height: 6)
            }
        }
        .help("\(identity.name): \(usage.words.formatted()) words in \(usage.dictations.formatted()) dictations")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(identity.name), \(usage.words) words in \(usage.dictations) dictations")
    }
}

/// Display name and icon for a Top apps group. Categories (from the App
/// categories feature) arrive as `.category` and need no lookup.
@MainActor
enum InsightsAppIdentity {
    private static var cache: [String: (name: String, icon: NSImage?)] = [:]

    static func resolve(_ group: InsightsAppGroup) -> (name: String, icon: NSImage?) {
        switch group {
        case .category(let name): return (name, nil)
        case .unknown: return ("Other and earlier dictations", nil)
        case .application(let bundleID):
            if let cached = cache[bundleID] { return cached }
            let resolved: (name: String, icon: NSImage?)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let name = FileManager.default.displayName(atPath: url.path)
                resolved = (name.hasSuffix(".app") ? String(name.dropLast(4)) : name, NSWorkspace.shared.icon(forFile: url.path))
            } else {
                resolved = (bundleID, nil)
            }
            cache[bundleID] = resolved
            return resolved
        }
    }
}
