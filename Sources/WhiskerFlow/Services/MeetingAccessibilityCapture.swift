import AppKit
import ApplicationServices
import Logging
import WhiskerFlowAppSupport

/// Native, recording-scoped reader. No browser injection, extension, audio upload or CC dependency.
@MainActor
final class MeetingAccessibilityCapture {
    private var task: Task<Void, Never>?
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.MeetingProcessing")
    private var lastProbeSignature: String?
    var onStatus: ((String) -> Void)?

    func start(sessionID: UUID, startMs: Int64, store: EncryptedMeetingChunkStore, expectedMeetingURL: String? = nil) {
        task?.cancel()
        lastProbeSignature = nil
        if let expectedMeetingURL, URL(string: expectedMeetingURL)?.host != "meet.google.com" {
            onStatus?("Speaker names are available for supported Google Meet calls")
            return
        }
        let expectedPath = expectedMeetingURL.flatMap(URL.init(string:)).flatMap {
            $0.host == "meet.google.com" ? $0.path : nil
        }
        task = Task { [weak self] in
            var timeline = MeetingAccessibilityTimeline()
            while !Task.isCancelled {
                let pids = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == "com.google.Chrome" ||
                    $0.bundleIdentifier == "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
                }.map(\.processIdentifier)
                let worker = Task.detached(priority: .utility) { MeetingAccessibilityReader.read(pids: pids) }
                let result = await worker.value
                guard !Task.isCancelled else { return }
                let now = Int64(Date().timeIntervalSince1970 * 1000) - startMs
                var matching = result.snapshot.flatMap { snapshot in
                    expectedPath == nil || snapshot.meetingID == expectedPath ? snapshot : nil
                }
                var visualReadFailed = false
                if let snapshot = matching, snapshot.speakers.isEmpty, !snapshot.visualTiles.isEmpty {
                    matching = await MeetingVisualSpeakerReader.read(snapshot)
                    visualReadFailed = matching == nil
                }
                guard !Task.isCancelled else { return }
                // Timestamp after all reads. Slow frames must not bridge stale activity.
                let observedMs = Int64(Date().timeIntervalSince1970 * 1000) - startMs
                let evidence = timeline.observe(observedMs - now <= 650 ? matching : nil, atMs: observedMs)
                let availability = matching == nil && result.snapshot != nil
                    ? MeetingAccessibilityAvailability.unavailable.rawValue
                    : result.availability.rawValue
                let speakerCount = matching?.speakers.count ?? 0
                let visualTileCount = matching?.visualTiles.count ?? 0
                let visualFailure = visualReadFailed ? "true" : "false"
                let probeSignature = "\(availability)|\(speakerCount)|\(visualTileCount)|\(visualFailure)"
                if probeSignature != self?.lastProbeSignature {
                    self?.lastProbeSignature = probeSignature
                    self?.logger.info("Meet speaker probe", metadata: [
                        "event": .string("meeting_speaker_probe"),
                        "availability": .string(availability),
                        "speaker_count": .string(String(speakerCount)),
                        "visual_tile_count": .string(String(visualTileCount)),
                        "visual_read_failed": .string(visualFailure)
                    ])
                }
                if !evidence.isEmpty {
                    let saved = await Task.detached(priority: .utility) {
                        do { try store.saveSpeakerEvidence(sessionID: sessionID, evidence: evidence); return true }
                        catch { return false }
                    }.value
                    guard !Task.isCancelled else { return }
                    self?.onStatus?(saved ? "Meet speaker activity detected" : "Speaker evidence could not be saved")
                } else {
                    self?.onStatus?(visualReadFailed ? "Meet visual speaker activity is temporarily unavailable" : matching != nil
                        ? "Waiting for supported Meet speaker activity"
                        : (result.snapshot != nil ? "Speaker information belongs to a different call" : result.unavailableDetail))
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
    func stop() async {
        let pending = task
        task?.cancel()
        task = nil
        await pending?.value
    }
}

struct MeetingAccessibilityReadResult: Sendable {
    let snapshot: MeetingAccessibilitySnapshot?
    let unavailableDetail: String
    let availability: MeetingAccessibilityAvailability
}

enum MeetingAccessibilityReader {
    /// Bounded AX requests are synchronous IPC and must never execute on the main actor.
    static func read(pids: [pid_t]) -> MeetingAccessibilityReadResult {
        guard AXIsProcessTrusted() else {
            return .init(snapshot: nil, unavailableDetail: "Accessibility permission is needed for speaker names", availability: .unavailable)
        }
        guard !pids.isEmpty else {
            return .init(snapshot: nil, unavailableDetail: "Open the Meet call in Chrome for speaker names", availability: .unavailable)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.50
        var remaining = 700
        var complete = true
        var failureDetail = "Meet speaker information could not be read completely"
        func attribute(_ node: AXUIElement, _ key: String, required: Bool = true) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false; failureDetail = "Meet speaker information took too long to read"; return nil
            }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(node, key as CFString, &value)
            if error == .cannotComplete || error == .invalidUIElement {
                if required { complete = false }
            }
            return error == .success ? value : nil
        }
        func project(_ node: AXUIElement, pid: pid_t, depth: Int) -> MeetingAccessibilityNode? {
            guard remaining > 0, depth < 32, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                failureDetail = ProcessInfo.processInfo.systemUptime >= deadline
                    ? "Meet speaker information took too long to read"
                    : "Meet speaker information exceeded the reading limit"
                return nil
            }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.05)
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            // Never descend into captions or editable/chat text. Status images/groups suffice.
            if ["AXTextArea", "AXTextField"].contains(role) { return nil }
            let label = [attribute(node, kAXDescriptionAttribute) as? String,
                         attribute(node, kAXTitleAttribute) as? String,
                         role == "AXStaticText" ? attribute(node, kAXValueAttribute) as? String : nil]
                .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
            var frame: CGRect?
            if ["AXWindow", "AXGroup", "AXStaticText"].contains(role),
               let rawPosition = attribute(node, kAXPositionAttribute, required: false),
               let rawSize = attribute(node, kAXSizeAttribute, required: false),
               CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
                var position = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
                   AXValueGetValue(rawSize as! AXValue, .cgSize, &size) { frame = CGRect(origin: position, size: size) }
            }
            if label.lowercased() == "captions" { return nil }
            let rawURL = role == "AXWebArea" ? attribute(node, "AXURL") : nil
            let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String)
            if role == "AXWebArea", url.flatMap(URL.init(string:))?.host != "meet.google.com" { return nil }
            var children: [MeetingAccessibilityNode] = []
            if !["AXImage", "AXStaticText"].contains(role) {
                var count: CFIndex = 0
                if AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) == .success, count > 0 {
                    guard count <= remaining else {
                        complete = false; failureDetail = "Meet speaker information exceeded the reading limit"; return nil
                    }
                    var values: CFArray?
                    if AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
                       let nodes = values as? [AXUIElement] {
                        for child in nodes {
                            if let value = project(child, pid: pid, depth: depth + 1) { children.append(value) }
                            if !complete { break }
                        }
                    } else { complete = false }
                }
            }
            return .init(id: "\(pid):\(CFHash(node))", role: role, label: label, url: url, frame: frame, children: children)
        }
        var roots: [MeetingAccessibilityNode] = []
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
                for window in windows {
                    if let root = project(window, pid: pid, depth: 0) { roots.append(root) }
                    if !complete { break }
                }
            }
            if !complete { break }
        }
        guard complete else {
            return .init(snapshot: nil, unavailableDetail: failureDetail, availability: .unavailable)
        }
        let assessment = MeetingAccessibilityEvidence.assess(roots: roots)
        let detail: String
        switch assessment.availability {
        case .available: detail = "Waiting for supported Meet speaker activity"
        case .noMeeting: detail = "No supported Meet call is visible to speaker detection"
        case .multipleMeetings: detail = "Multiple Meet calls are visible; speaker names are unavailable"
        case .notJoined: detail = "Join the Meet call to detect speaker names"
        case .unavailable: detail = "Meet speaker information is temporarily unavailable"
        }
        return .init(snapshot: assessment.snapshot, unavailableDetail: detail, availability: assessment.availability)
    }
}
