import AppKit
import ApplicationServices
import WhiskerFlowAppSupport

/// Reads only the active Google Meet caption region using existing accessibility access.
/// All AX work and encrypted writes run off the main thread and have bounded work.
@MainActor
final class MeetingCaptionCapture {
    private var task: Task<Void, Never>?
    func start(sessionID: UUID, store: EncryptedMeetingChunkStore) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled && self != nil {
                let pids = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == "com.google.Chrome" ||
                    $0.bundleIdentifier == "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
                }.map(\.processIdentifier)
                let worker = Task.detached(priority: .utility) {
                    let rows = MeetingCaptionReader.read(pids: pids)
                    if !rows.isEmpty { try? store.saveCaptionEvidence(sessionID: sessionID, evidence: rows) }
                }
                await worker.value
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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

enum MeetingCaptionReader {
    static func read(pids: [pid_t], report: @Sendable ([String: Int]) -> Void = { _ in }) -> [MeetingCaptionEvidence] {
        var metrics = ["nodes": 0, "web_areas": 0, "meet_areas": 0, "caption_regions": 0, "trusted": AXIsProcessTrusted() ? 1 : 0]
        defer { report(metrics) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3.0
        var result: [MeetingCaptionEvidence] = []
        var captionRegions = 0
        for pid in pids {
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.05)
            var queue: [(AXUIElement, Bool)] = [(root, false)]
            var index = 0
            while !queue.isEmpty && index < 2500 && ProcessInfo.processInfo.systemUptime < deadline {
                let (node, inheritedMeet) = queue.removeLast(); index += 1
                AXUIElementSetMessagingTimeout(node, 0.05)
                metrics["nodes", default: 0] += 1
                let role = string(node, kAXRoleAttribute)
                if role == "AXWebArea" { metrics["web_areas", default: 0] += 1 }
                if role == kAXStaticTextRole || role == kAXButtonRole { continue }
                let url = attribute(node, "AXURL").flatMap { ($0 as? URL)?.absoluteString ?? ($0 as? String) }
                let isMeet = role == "AXWebArea" ? url.flatMap(URL.init(string:))?.host == "meet.google.com" : inheritedMeet
                if isMeet && role == "AXWebArea" { metrics["meet_areas", default: 0] += 1 }
                let label = string(node, kAXDescriptionAttribute) ?? string(node, kAXTitleAttribute)
                let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
                if isMeet && label == "Captions" {
                    metrics["caption_regions", default: 0] += 1
                    captionRegions += 1
                    guard captionRegions == 1 else { return [] }
                    metrics["caption_children", default: 0] += children.count
                    for row in children.prefix(1000) {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { return result }
                        AXUIElementSetMessagingTimeout(row, 0.05)
                        let cells = attribute(row, kAXChildrenAttribute) as? [AXUIElement] ?? []
                        metrics["cells", default: 0] += cells.count
                        for cell in cells { metrics["role_" + (string(cell, kAXRoleAttribute) ?? "missing"), default: 0] += 1 }
                        guard cells.count == 2 else { continue }
                        var texts: [String] = []
                        for group in cells {
                            var parts: [String] = []
                            var pending = [group]
                            var traversed = 0
                            while let cell = pending.popLast(), traversed < 80, ProcessInfo.processInfo.systemUptime < deadline {
                                traversed += 1
                                AXUIElementSetMessagingTimeout(cell, 0.05)
                                if string(cell, kAXRoleAttribute) == kAXStaticTextRole {
                                    if let value = string(cell, kAXValueAttribute) ?? string(cell, kAXTitleAttribute), parts.last != value { parts.append(value) }
                                } else {
                                    pending.append(contentsOf: (attribute(cell, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed())
                                }
                            }
                            texts.append(parts.joined(separator: " "))
                        }
                        metrics["text_values", default: 0] += texts.count
                        if texts.count == 2, !texts[0].isEmpty, texts[0].count <= 150,
                           !texts[1].isEmpty, texts[1].count <= 12000 {
                            result.append(.init(speaker: texts[0], text: texts[1]))
                        }
                    }
                    continue
                }
                queue.append(contentsOf: children.reversed().map { ($0, isMeet) })
            }
        }
        return Array(result.suffix(1000))
    }
    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }
    private static func string(_ node: AXUIElement, _ key: String) -> String? { attribute(node, key) as? String }
}
