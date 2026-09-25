import Foundation
import CoreGraphics

/// A minimal, content-free-of-transcripts projection of Meet's accessibility tree.
/// Only explicit speaker status labels are interpreted; captions and roster order are not evidence.
public struct MeetingAccessibilityNode: Sendable {
    public var id: String
    public var role: String
    public var label: String
    public var url: String?
    public var frame: CGRect?
    public var children: [MeetingAccessibilityNode]
    public init(id: String, role: String, label: String = "", url: String? = nil, frame: CGRect? = nil, children: [Self] = []) {
        self.id = id; self.role = role; self.label = label; self.url = url; self.frame = frame; self.children = children
    }
}

public struct MeetingVisualTile: Sendable {
    public let id: String
    public let name: String
    public let frame: CGRect
}

public struct MeetingAccessibilitySnapshot: Sendable {
    public var meetingID: String
    public var speakers: [String: String]
    public var visualTiles: [MeetingVisualTile] = []
    public var windowFrame: CGRect?
    public var processID: Int32?
    public init(meetingID: String, speakers: [String: String]) {
        self.meetingID = meetingID; self.speakers = speakers
    }
}

/// Fixed categories only: safe to inspect without retaining meeting URLs or names.
public enum MeetingAccessibilityAvailability: String, Sendable {
    case available, noMeeting, multipleMeetings, notJoined
    case unavailable
}

public enum MeetingCaptureStopPolicy {
    /// Calendar end is only a prompt to check the call. Keep recording when
    /// the accessibility read is ambiguous or temporarily unavailable.
    public static func shouldStopAtCalendarBoundary(
        _ availability: MeetingAccessibilityAvailability
    ) -> Bool {
        availability == .noMeeting || availability == .notJoined
    }
}

public struct MeetingAccessibilityAssessment: Sendable {
    public let snapshot: MeetingAccessibilitySnapshot?
    public let availability: MeetingAccessibilityAvailability
}

public enum MeetingAccessibilityEvidence {
    public static func isJoined(_ node: MeetingAccessibilityNode) -> Bool {
        if node.role == "AXButton", ["Leave call", "Leave meeting"].contains(node.label) { return true }
        guard !["AXTextArea", "AXTextField", "AXStaticText"].contains(node.role), node.label.lowercased() != "captions" else { return false }
        return node.children.contains(where: isJoined)
    }

    public static func snapshot(roots: [MeetingAccessibilityNode]) -> MeetingAccessibilitySnapshot? {
        assess(roots: roots).snapshot
    }

    public static func assess(roots: [MeetingAccessibilityNode]) -> MeetingAccessibilityAssessment {
        var meetings: [MeetingAccessibilityNode] = []
        func discover(_ node: MeetingAccessibilityNode) {
            if node.role == "AXWebArea" {
                if let raw = node.url, let url = URL(string: raw), url.scheme == "https", url.host == "meet.google.com",
                   url.path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil {
                    meetings.append(node)
                }
                return
            }
            node.children.forEach(discover)
        }
        roots.forEach(discover)
        // Do not attach another call's activity to the recording.
        guard !meetings.isEmpty else { return .init(snapshot: nil, availability: .noMeeting) }
        guard meetings.count == 1 else { return .init(snapshot: nil, availability: .multipleMeetings) }
        let meeting = meetings[0]
        guard isJoined(meeting) else { return .init(snapshot: nil, availability: .notJoined) }
        var speakers: [String: String] = [:]
        func visit(_ node: MeetingAccessibilityNode) {
            guard !isCaptionRegion(node), node.role != "AXTextField", node.role != "AXTextArea" else { return }
            // Chrome exposes Meet's live speaking announcement as either an
            // image/group description or static text, depending on the
            // current Chromium accessibility tree. Static text is accepted
            // only for the explicit status grammar below; roster names and
            // captions do not match that grammar.
            if ["AXGroup", "AXImage", "AXStaticText"].contains(node.role),
               let name = explicitSpeakerName(node.label) {
                speakers[node.id] = name
            }
            node.children.forEach(visit)
        }
        visit(meeting)
        var snapshot = MeetingAccessibilitySnapshot(meetingID: URL(string: meeting.url!)!.path, speakers: speakers)
        func tiles(_ node: MeetingAccessibilityNode) {
            guard !["AXTextArea", "AXTextField"].contains(node.role), !isCaptionRegion(node) else { return }
            let names = node.children.filter { $0.role == "AXStaticText" && !$0.label.isEmpty }
            if node.role == "AXGroup", names.count == 1, let nameFrame = names[0].frame,
               nameFrame.width >= 8, nameFrame.height >= 8, nameFrame.height <= 60,
               names[0].label.count <= 150, !names[0].label.contains("\n"),
               names[0].label.rangeOfCharacter(from: .letters) != nil {
                snapshot.visualTiles.append(.init(id: node.id, name: names[0].label, frame: nameFrame))
            }
            node.children.forEach(tiles)
        }
        tiles(meeting)
        func containsMeeting(_ node: MeetingAccessibilityNode) -> Bool {
            node.id == meeting.id || node.children.contains(where: containsMeeting)
        }
        func window(_ node: MeetingAccessibilityNode) {
            if node.role == "AXWindow", containsMeeting(node) {
                snapshot.windowFrame = node.frame
                snapshot.processID = node.id.split(separator: ":").first.flatMap { Int32($0) }
            } else { node.children.forEach(window) }
        }
        roots.forEach(window)
        return .init(snapshot: snapshot, availability: .available)
    }

    private static func isCaptionRegion(_ node: MeetingAccessibilityNode) -> Bool {
        let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return label == "captions" || label.hasPrefix("captions ") || label.hasPrefix("live captions")
    }

    /// Deliberately narrow English status grammar. Unknown/localised layouts remain unnamed.
    /// A microphone being unmuted, a roster entry or an audio icon alone is never speaking proof.
    public static func explicitSpeakerName(_ label: String) -> String? {
        let suffix = " is speaking"
        guard label.hasSuffix(suffix) else { return nil }
        let name = String(label.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 150, !name.contains("\n"),
              !["you", "someone", "participant"].contains(name.lowercased()) else { return nil }
        return name
    }
}

/// Only the interval between two fresh agreeing observations can become evidence.
/// Missing/ambiguous trees break continuity; never extrapolate through hidden tabs or slow AX calls.
public struct MeetingAccessibilityTimeline: Sendable {
    private var meetingID: String?
    private var previous: (Int64, MeetingAccessibilitySnapshot)?
    public init() {}
    public mutating func observe(_ snapshot: MeetingAccessibilitySnapshot?, atMs: Int64) -> [MeetingSpeakerEvidence] {
        guard let snapshot, atMs >= 0 else { previous = nil; return [] }
        if meetingID == nil { meetingID = snapshot.meetingID }
        guard meetingID == snapshot.meetingID else { previous = nil; return [] }
        defer { previous = (atMs, snapshot) }
        guard let (before, prior) = previous, atMs > before, atMs - before <= 1500 else { return [] }
        return snapshot.speakers.compactMap { id, name in
            guard prior.speakers[id] == name else { return nil }
            return .init(startMs: before, endMs: atMs, participantID: "ax:" + snapshot.meetingID + ":" + id, displayName: name)
        }
    }
}
