import SwiftUI
import WhiskerFlowCore

struct MeetingCoachView: View {
    @Bindable var controller: MeetingAssistantController
    let requestPreparation: @MainActor () async -> Void
    let requestReview: @MainActor () async -> Void
    @State private var bookmarkLabel = ""
    @State private var bookmarkFeedback: String?

    init(
        controller: MeetingAssistantController,
        requestPreparation: @escaping @MainActor () async -> Void,
        requestReview: @escaping @MainActor () async -> Void
    ) {
        self.controller = controller
        self.requestPreparation = requestPreparation
        self.requestReview = requestReview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Private meeting coach", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                Toggle("Coach", isOn: $controller.isCoachEnabled).toggleStyle(.switch)
            }
            Text("Coaching stays private to you. Live estimates use only microphone and Mac-audio activity.")
                .font(.caption).foregroundStyle(FlowStyle.muted)

            TextField("What do you want from this meeting?", text: $controller.goal)
                .textFieldStyle(.roundedBorder)
            TextField("Agenda or checklist", text: $controller.agenda, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
            Button("Prepare") { Task { await requestPreparation() } }
                .disabled(controller.isActive)

            if controller.isActive {
                Divider()
                HStack {
                    Text(controller.activeTitle ?? "Meeting in progress").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(Self.duration(controller.elapsedSeconds)).monospacedDigit()
                }
                if controller.isCoachEnabled {
                    if controller.isCoachVisible {
                        Text("Own-microphone activity estimate: \(Int(controller.activity.ownMicActiveSeconds))s of the last \(Int(controller.activity.windowDurationSeconds))s")
                            .font(.callout)
                        Text(certaintyLabel).font(.caption).foregroundStyle(FlowStyle.muted)
                        if let prompt = controller.livePrompt {
                            HStack(alignment: .top) {
                                Text(prompt).font(.callout)
                                Spacer()
                                Button("Dismiss") { controller.dismissPrompt() }.buttonStyle(.plain)
                            }
                        }
                    }
                    HStack {
                        Button(controller.isCoachPaused ? "Resume coaching" : "Pause coaching") {
                            controller.isCoachPaused.toggle()
                        }
                        Button(controller.isCoachVisible ? "Hide coach" : "Show coach") {
                            controller.isCoachVisible.toggle()
                        }
                    }
                }
                HStack {
                    TextField("Optional bookmark label · ⌥⇧⌘B bookmarks immediately", text: $bookmarkLabel).textFieldStyle(.roundedBorder)
                    Button("Bookmark") {
                        do {
                            let bookmark = try controller.addBookmark(label: bookmarkLabel)
                            bookmarkFeedback = "Bookmarked at \(Self.duration(Double(bookmark.elapsedMilliseconds) / 1_000))."
                            bookmarkLabel = ""
                        } catch {
                            bookmarkFeedback = "The bookmark could not be saved."
                        }
                    }
                }
                if let bookmarkFeedback {
                    Text(bookmarkFeedback).font(.caption).foregroundStyle(FlowStyle.muted)
                }
            }
            if !controller.isActive, let summary = controller.localReview {
                DisclosureGroup("Local meeting recap") { Text(summary).font(.callout).textSelection(.enabled).padding(.top, 8) }
            }
            if !controller.isActive, controller.latestFinalizedMeetingReference != nil {
                Button("Review latest meeting") { Task { await requestReview() } }
            }
            if let error = controller.storageError { Text(error).font(.callout).foregroundStyle(.orange) }
            if !controller.bookmarks.isEmpty {
                DisclosureGroup("Saved bookmarks (\(controller.bookmarks.count))") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(controller.bookmarks.reversed()) { bookmark in
                                HStack {
                                    Text(Self.duration(Double(bookmark.elapsedMilliseconds) / 1000)).monospacedDigit()
                                    Text(bookmark.label ?? "Bookmarked moment").lineLimit(2)
                                    Spacer()
                                    Text(bookmark.syncState == .synced ? "In Atlas" : "On this Mac")
                                        .font(.caption).foregroundStyle(FlowStyle.muted)
                                    if bookmark.syncState != .synced {
                                        Button("Retry") { Task { await controller.retryPendingBookmarks(sessionID: bookmark.sessionID) } }
                                    }
                                }.font(.callout)
                            }
                        }.padding(.vertical, 10)
                    }.frame(maxHeight: 220)
                }
            }
        }
        .padding(18)
        .background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var certaintyLabel: String {
        switch controller.activity.certainty {
        case .reliable: return "Estimated from both audio tracks."
        case .missingOwnMicTrack: return "Estimate uncertain: microphone activity is missing."
        case .missingSystemTrack: return "Estimate uncertain: Mac-audio activity is missing."
        case .missingBothTracks: return "Estimate unavailable: both activity tracks are missing."
        case .uncertainOverlap: return "Estimate uncertain: microphone and Mac audio overlap."
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
