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
        // Same normalisation as the AX web-area path: whitespace, case or a
        // trailing slash in the calendar URL must not disable speaker capture.
        let expectedPath = expectedMeetingURL.flatMap(MeetingAccessibilityEvidence.expectedMeetingPath)
        if expectedMeetingURL != nil, expectedPath == nil {
            onStatus?("Speaker names are available for supported Google Meet calls")
            return
        }
        task = Task { [weak self] in
            var timeline = MeetingAccessibilityTimeline()
            var policy = MeetingSpeakerPollingPolicy()
            var buffer = MeetingSpeakerEvidenceBuffer()
            var saveFailed = false
            // Screenshot awaiting confirmation by the next AX read, with the
            // completion time of the AX read it was based on.
            var pendingFrame: (frame: MeetingVisualFrame, basedOnMs: Int64)?
            func elapsedMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) - startMs }
            func save(_ rows: [MeetingSpeakerEvidence]) async -> Bool {
                await Task.detached(priority: .utility) {
                    do { try store.saveSpeakerEvidence(sessionID: sessionID, evidence: rows); return true }
                    catch { return false }
                }.value
            }
            while !Task.isCancelled {
                let cycleStartMs = elapsedMs()
                let pids = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == "com.google.Chrome" ||
                    $0.bundleIdentifier == "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
                }.map(\.processIdentifier)
                let worker = Task.detached(priority: .utility) { MeetingAccessibilityReader.read(pids: pids) }
                let result = await worker.value
                guard !Task.isCancelled else { break }
                // Timestamp after the read. Slow reads must not bridge stale activity.
                let readMs = elapsedMs()
                let matching = result.snapshot.flatMap { snapshot in
                    expectedPath == nil || snapshot.meetingID == expectedPath ? snapshot : nil
                }
                let gapMs = policy.continuityGapMs
                var evidence: [MeetingSpeakerEvidence] = []
                var visualReadFailed = false
                var visual: MeetingAccessibilitySnapshot?
                // Pipelined visual fallback: the previous cycle's screenshot is
                // trusted only when the AX reads before and after it agree on the
                // call, window and tiles, so no second AX walk is needed per frame.
                if let pending = pendingFrame {
                    pendingFrame = nil
                    let frameMs = pending.frame.capturedAtMs - startMs
                    if let matching, frameMs - pending.basedOnMs <= gapMs {
                        let frame = pending.frame
                        visual = await Task.detached(priority: .utility) {
                            MeetingVisualSpeakerReader.analyze(frame, verifiedBy: matching)
                        }.value
                    }
                    visualReadFailed = visual == nil
                    evidence += timeline.observe(visual, atMs: frameMs, maximumGapMs: gapMs)
                }
                guard !Task.isCancelled else { break }
                if let snapshot = matching, snapshot.speakers.isEmpty, !snapshot.visualTiles.isEmpty {
                    if let frame = await MeetingVisualSpeakerReader.capture(snapshot) {
                        pendingFrame = (frame, readMs)
                    } else {
                        visualReadFailed = true
                        evidence += timeline.observe(nil, atMs: readMs)
                    }
                } else {
                    evidence += timeline.observe(matching, atMs: readMs, maximumGapMs: gapMs)
                }
                guard !Task.isCancelled else { break }
                policy.record(workMs: elapsedMs() - cycleStartMs, active: matching != nil)
                let availability = (matching == nil || visualReadFailed) && result.snapshot != nil
                    ? MeetingAccessibilityAvailability.unavailable.rawValue
                    : result.availability.rawValue
                let speakerCount = (visual ?? matching)?.speakers.count ?? 0
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
                buffer.append(evidence, atMs: readMs)
                // Batched: one encrypted file per flush interval, not per cycle.
                let due = buffer.drain(atMs: readMs)
                if !due.isEmpty {
                    saveFailed = !(await save(due))
                    guard !Task.isCancelled else { break }
                }
                if !evidence.isEmpty {
                    self?.onStatus?(saveFailed ? "Speaker evidence could not be saved" : "Meet speaker activity detected")
                } else {
                    self?.onStatus?(visualReadFailed ? "Meet visual speaker activity is temporarily unavailable" : matching != nil
                        ? "Waiting for supported Meet speaker activity"
                        : (result.snapshot != nil ? "Speaker information belongs to a different call" : result.unavailableDetail))
                }
                // Back off while no matching, joined call is readable (no Meet,
                // lobby, AX too slow, another call); a readable call resets it.
                try? await Task.sleep(nanoseconds: UInt64(policy.sleepMs) * 1_000_000)
            }
            // stop() awaits this task, so buffered evidence is on disk before
            // the session is processed.
            let remaining = buffer.drain(atMs: elapsedMs(), force: true)
            if !remaining.isEmpty { _ = await save(remaining) }
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
    /// Wall-clock budget for one read, sized for a busy base M1 or Intel Mac
    /// whose Chrome answers AX IPC slowly and whose utility work may run on
    /// efficiency cores, not for the development machine.
    static let readBudgetSeconds: TimeInterval = 2.0
    static let nodeBudget = 2_500
    static let maximumDepth = 48
    /// Upper bound per AX call; always clamped to the remaining read budget.
    static let callTimeoutSeconds: TimeInterval = 0.25

    /// Bounded AX requests are synchronous IPC and must never execute on the main actor.
    static func read(pids: [pid_t]) -> MeetingAccessibilityReadResult {
        guard AXIsProcessTrusted() else {
            return .init(snapshot: nil, unavailableDetail: "Accessibility permission is needed for speaker names", availability: .unavailable)
        }
        guard !pids.isEmpty else {
            return .init(snapshot: nil, unavailableDetail: "Open the Meet call in Chrome for speaker names", availability: .unavailable)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + readBudgetSeconds
        var walk = MeetingAccessibilityWalk(deadline: deadline)
        walk.run(pids: pids)
        // A node Meet destroys mid-walk is ordinary churn in a live call. Retry
        // within the same budget rather than report the call unavailable; a
        // partial tree is never assessed, so a missing Leave button cannot
        // masquerade as "not joined".
        if !walk.complete, walk.transient, ProcessInfo.processInfo.systemUptime < deadline {
            walk = MeetingAccessibilityWalk(deadline: deadline)
            walk.run(pids: pids)
        }
        guard walk.complete else {
            return .init(snapshot: nil, unavailableDetail: walk.failureDetail, availability: .unavailable)
        }
        let assessment = MeetingAccessibilityEvidence.assess(roots: walk.roots)
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

/// One all-or-nothing projection of Chrome's windows. Each node costs one
/// batched AX round trip (plus value/URL where needed) instead of one per attribute.
private struct MeetingAccessibilityWalk {
    let deadline: TimeInterval
    var remaining = MeetingAccessibilityReader.nodeBudget
    var complete = true
    /// Set when a failure came from a destroyed element rather than a timeout.
    var transient = false
    var failureDetail = "Meet speaker information could not be read completely"
    var roots: [MeetingAccessibilityNode] = []

    private static let nodeAttributes = [
        kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute
    ]
    private static let requiredNodeAttributes: Set<String> = [
        kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute
    ]

    init(deadline: TimeInterval) { self.deadline = deadline }

    mutating func run(pids: [pid_t]) {
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
                for window in windows {
                    if let root = project(window, pid: pid, depth: 0, insideWebArea: false) { roots.append(root) }
                    if !complete { break }
                }
            }
            if !complete { break }
        }
    }

    private mutating func fail(_ error: AXError) {
        if error == .invalidUIElement { transient = true }
        complete = false
    }

    /// Checks the budget and bounds the next call by what remains of it.
    private mutating func prepare(_ element: AXUIElement) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now < deadline else {
            complete = false; failureDetail = "Meet speaker information took too long to read"; return false
        }
        let timeout = min(MeetingAccessibilityReader.callTimeoutSeconds, max(0.01, deadline - now))
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        return true
    }

    private mutating func attribute(_ element: AXUIElement, _ key: String, required: Bool = true) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        if required, error == .cannotComplete || error == .invalidUIElement { fail(error) }
        return error == .success ? value : nil
    }

    private mutating func nodeValues(_ element: AXUIElement) -> [String: CFTypeRef] {
        guard prepare(element) else { return [:] }
        let keys = Self.nodeAttributes
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &raw)
        if error == .cannotComplete || error == .invalidUIElement { fail(error); return [:] }
        guard error == .success, let values = raw as? [AnyObject], values.count == keys.count else {
            // Batched reads unsupported by this element: fall back per attribute.
            var result: [String: CFTypeRef] = [:]
            for key in keys where complete {
                if let value = attribute(element, key, required: Self.requiredNodeAttributes.contains(key)) { result[key] = value }
            }
            return result
        }
        var result: [String: CFTypeRef] = [:]
        for (key, value) in zip(keys, values) {
            if value is NSNull { continue }
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var attributeError = AXError.success
                _ = AXValueGetValue(value as! AXValue, .axError, &attributeError)
                if Self.requiredNodeAttributes.contains(key),
                   attributeError == .cannotComplete || attributeError == .invalidUIElement { fail(attributeError) }
                continue
            }
            result[key] = value
        }
        return result
    }

    private mutating func project(_ node: AXUIElement, pid: pid_t, depth: Int, insideWebArea: Bool) -> MeetingAccessibilityNode? {
        guard remaining > 0, depth < MeetingAccessibilityReader.maximumDepth, ProcessInfo.processInfo.systemUptime < deadline else {
            complete = false
            failureDetail = ProcessInfo.processInfo.systemUptime >= deadline
                ? "Meet speaker information took too long to read"
                : "Meet speaker information exceeded the reading limit"
            return nil
        }
        remaining -= 1
        let values = nodeValues(node)
        guard complete else { return nil }
        let role = values[kAXRoleAttribute] as? String ?? ""
        // Never descend into captions or editable/chat text. Status images/groups suffice.
        if ["AXTextArea", "AXTextField"].contains(role) { return nil }
        // Chrome's tab strip, toolbar and bookmarks bar cannot contain the call.
        if !insideWebArea, ["AXTabGroup", "AXToolbar"].contains(role) { return nil }
        var label = [values[kAXDescriptionAttribute] as? String, values[kAXTitleAttribute] as? String]
            .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        if label.isEmpty, role == "AXStaticText" {
            label = attribute(node, kAXValueAttribute) as? String ?? ""
            guard complete else { return nil }
        }
        var frame: CGRect?
        if ["AXWindow", "AXGroup", "AXStaticText"].contains(role),
           let rawPosition = values[kAXPositionAttribute], let rawSize = values[kAXSizeAttribute],
           CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var position = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
               AXValueGetValue(rawSize as! AXValue, .cgSize, &size) { frame = CGRect(origin: position, size: size) }
        }
        if label.lowercased() == "captions" { return nil }
        let rawURL = role == "AXWebArea" ? attribute(node, "AXURL") : nil
        guard complete else { return nil }
        let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String)
        if role == "AXWebArea", url.flatMap(URL.init(string:))?.host != "meet.google.com" { return nil }
        var children: [MeetingAccessibilityNode] = []
        if !["AXImage", "AXStaticText"].contains(role),
           let nodes = values[kAXChildrenAttribute] as? [AXUIElement], !nodes.isEmpty {
            guard nodes.count <= remaining else {
                complete = false; failureDetail = "Meet speaker information exceeded the reading limit"; return nil
            }
            for child in nodes {
                if let value = project(child, pid: pid, depth: depth + 1, insideWebArea: insideWebArea || role == "AXWebArea") {
                    children.append(value)
                }
                if !complete { break }
            }
        }
        return .init(id: "\(pid):\(CFHash(node))", role: role, label: label, url: url, frame: frame, children: children)
    }
}
