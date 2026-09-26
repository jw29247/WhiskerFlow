import Foundation

/// Call platforms WhiskerFlow recognises, in their native apps or a browser.
public enum CallPlatform: String, Codable, CaseIterable, Sendable {
    case googleMeet
    case zoom
    case teams
    case slackHuddle
    case webex

    public var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .slackHuddle: return "Slack huddle"
        case .webex: return "Webex"
        }
    }

    /// Hosts of this platform's join links, as found in calendar events.
    public var joinHosts: [String] {
        switch self {
        case .googleMeet: return ["meet.google.com"]
        case .zoom: return ["zoom.us", "zoomgov.com"]
        case .teams: return ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"]
        case .slackHuddle: return ["slack.com"]
        case .webex: return ["webex.com"]
        }
    }
}

/// A process that is capturing microphone input right now (CoreAudio's
/// `kAudioProcessPropertyIsRunningInput`). Helper processes report their own
/// bundle identifier.
public struct AudioInputProcess: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Window and tab titles of one running app, read through Accessibility. They
/// are used in memory to recognise a call and never stored or logged.
public struct AppWindowTitles: Equatable, Sendable {
    public let bundleID: String
    public let titles: [String]

    public init(bundleID: String, titles: [String]) {
        self.bundleID = bundleID
        self.titles = titles
    }
}

public struct DetectedCall: Equatable, Identifiable, Sendable {
    /// Stable while the call runs: one call per platform and app.
    public var id: String { "\(platform.rawValue)|\(appBundleID)" }
    public let platform: CallPlatform
    /// The app that owns the call (the browser, for a web call).
    public let appBundleID: String
    public let isBrowser: Bool
    /// The Google Meet code (`abc-defg-hij`), when the title shows it.
    public let meetingCode: String?

    public init(platform: CallPlatform, appBundleID: String, isBrowser: Bool, meetingCode: String? = nil) {
        self.platform = platform
        self.appBundleID = appBundleID
        self.isBrowser = isBrowser
        self.meetingCode = meetingCode
    }
}

/// Decides which calls are live from two native signals: which apps are
/// using the microphone, and the titles of their windows and tabs. No browser
/// extension, network access or screen image is involved.
public enum CallDetectionRules {
    /// Desktop call apps. Using the microphone is itself the call signal: these
    /// apps open it only for calls (Slack also for short clips).
    public static let nativeApps: [String: CallPlatform] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams,
        "com.tinyspeck.slackmacgap": .slackHuddle,
        "Cisco-Systems.Spark": .webex,
        "com.webex.meetingmanager": .webex,
        "com.cisco.webexmeetingsapp": .webex,
    ]

    /// Browsers whose tabs can host a web call.
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.kagi.kagimacOS",
    ]

    /// Browsers built on the system WebKit. Their media capture runs in shared
    /// `com.apple.WebKit.*` processes, which no single browser owns.
    public static let webKitBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"]

    static let webKitProcessMarker = "com.apple.WebKit"

    /// The browser whose microphone capture a running app's windows belong
    /// to: the browser itself, or one of its installed web apps. Chromium
    /// web apps (such as the Google Meet app) run as `<browser>.app.<id>`
    /// but capture audio in the browser's helper; Safari's Dock web apps
    /// (`com.apple.Safari.WebApp.<id>`) capture in shared WebKit processes.
    public static func titleSourceOwner(forAppBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if browsers.contains(bundleID) { return bundleID }
        if bundleID.hasPrefix("com.apple.Safari.WebApp") { return "com.apple.Safari" }
        return browsers.first { bundleID.hasPrefix($0 + ".app.") }
    }

    /// The app bundle a (possibly helper) process belongs to, if it is one
    /// WhiskerFlow knows. `nil` for everything else.
    public static func owningApp(ofProcessBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if bundleID.hasPrefix(webKitProcessMarker) { return webKitProcessMarker }
        let known = browsers.union(nativeApps.keys)
        if known.contains(bundleID) { return bundleID }
        // Helpers extend the app's identifier: com.google.Chrome.helper,
        // com.tinyspeck.slackmacgap.helper, us.zoom.CptHost is not a prefix
        // match and is handled by the zoom app itself.
        return known.filter { bundleID.hasPrefix($0 + ".") }.max { $0.count < $1.count }
    }

    /// Recognises a web call from a browser window or tab title.
    public static func webCall(inTitle title: String) -> (platform: CallPlatform, meetingCode: String?)? {
        let lower = title.lowercased()
        if let code = meetCode(in: lower), lower.contains("meet") { return (.googleMeet, code) }
        if lower.contains("meet.google.com") || lower.hasPrefix("google meet") { return (.googleMeet, nil) }
        if lower.contains("microsoft teams") || lower.contains("teams.microsoft.com") { return (.teams, nil) }
        if lower.contains("zoom.us") || (lower.contains("zoom") && (lower.contains("meeting") || lower.contains("webinar"))) {
            return (.zoom, nil)
        }
        if lower.contains("webex") { return (.webex, nil) }
        if lower.contains("huddle") && lower.contains("slack") { return (.slackHuddle, nil) }
        return nil
    }

    /// A Google Meet code such as `abc-defg-hij`.
    public static func meetCode(in text: String) -> String? {
        let pattern = #"(?<![a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])"#
        guard let range = text.lowercased().range(of: pattern, options: .regularExpression) else { return nil }
        return String(text.lowercased()[range])
    }

    public static func detect(
        inputs: [AudioInputProcess],
        windows: [AppWindowTitles],
        ownBundleID: String?
    ) -> [DetectedCall] {
        var owners: [String] = []
        for process in inputs {
            guard process.bundleID != ownBundleID,
                  !(ownBundleID.map { process.bundleID?.hasPrefix($0 + ".") == true } ?? false),
                  let owner = owningApp(ofProcessBundleID: process.bundleID),
                  !owners.contains(owner) else { continue }
            owners.append(owner)
        }
        var calls: [DetectedCall] = []
        for owner in owners {
            if let platform = nativeApps[owner] {
                calls.append(DetectedCall(platform: platform, appBundleID: owner, isBrowser: false))
                continue
            }
            // A WebKit capture process can belong to any WebKit browser.
            let candidates = owner == webKitProcessMarker
                ? windows.filter { webKitBrowsers.contains($0.bundleID) }
                : windows.filter { $0.bundleID == owner }
            if let match = firstWebCall(in: candidates) {
                calls.append(DetectedCall(platform: match.platform, appBundleID: match.bundleID,
                                          isBrowser: true, meetingCode: match.code))
            }
        }
        var seen: Set<String> = []
        return calls.filter { seen.insert($0.id).inserted }
    }

    private static func firstWebCall(in windows: [AppWindowTitles]) -> (platform: CallPlatform, code: String?, bundleID: String)? {
        // Chromium marks the tab using the microphone ("… – Microphone recording");
        // prefer it over other call tabs that may be open in the background.
        for preferCapturing in [true, false] {
            for window in windows {
                for title in window.titles {
                    let capturing = title.lowercased().contains("microphone") || title.lowercased().contains("recording")
                    guard capturing == preferCapturing, let call = webCall(inTitle: title) else { continue }
                    return (call.platform, call.meetingCode, window.bundleID)
                }
            }
        }
        return nil
    }
}

/// Turns per-poll detections into call start and end events. A call starts
/// after it has been seen on consecutive polls (so an audio test or a brief
/// clip doesn't prompt) and ends once its app has stopped using the
/// microphone for a grace period (so a mute or device switch doesn't).
public struct CallSessionTracker: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case started(DetectedCall)
        case ended(DetectedCall)
    }

    private struct Tracked: Equatable, Sendable {
        var call: DetectedCall
        var confirmations: Int
        var lastSeen: TimeInterval
        var announced: Bool
    }

    public let startConfirmations: Int
    public let endGraceSeconds: TimeInterval
    private var tracked: [String: Tracked] = [:]

    public init(startConfirmations: Int = 2, endGraceSeconds: TimeInterval = 15) {
        self.startConfirmations = max(1, startConfirmations)
        self.endGraceSeconds = max(0, endGraceSeconds)
    }

    public var activeCalls: [DetectedCall] {
        tracked.values.filter(\.announced).map(\.call).sorted { $0.id < $1.id }
    }

    /// - Parameters:
    ///   - calls: calls recognised in this poll.
    ///   - appsUsingMicrophone: owning apps still capturing input. A started
    ///     call stays alive while its app keeps the microphone open, even if
    ///     its title could not be read this time.
    public mutating func observe(
        _ calls: [DetectedCall], appsUsingMicrophone: Set<String>, at now: TimeInterval
    ) -> [Event] {
        var events: [Event] = []
        let seenIDs = Set(calls.map(\.id))
        for call in calls {
            var entry = tracked[call.id] ?? Tracked(call: call, confirmations: 0, lastSeen: now, announced: false)
            entry.call = call.meetingCode == nil && entry.call.meetingCode != nil
                ? DetectedCall(platform: call.platform, appBundleID: call.appBundleID, isBrowser: call.isBrowser,
                               meetingCode: entry.call.meetingCode)
                : call
            entry.confirmations += 1
            entry.lastSeen = now
            if !entry.announced, entry.confirmations >= startConfirmations {
                entry.announced = true
                events.append(.started(entry.call))
            }
            tracked[call.id] = entry
        }
        for (id, var entry) in tracked where !seenIDs.contains(id) {
            if entry.announced, appsUsingMicrophone.contains(entry.call.appBundleID)
                || (entry.call.isBrowser && appsUsingMicrophone.contains(CallDetectionRules.webKitProcessMarker)
                    && CallDetectionRules.webKitBrowsers.contains(entry.call.appBundleID)) {
                entry.lastSeen = now
                tracked[id] = entry
                continue
            }
            if !entry.announced {
                tracked[id] = nil
            } else if now - entry.lastSeen >= endGraceSeconds {
                tracked[id] = nil
                events.append(.ended(entry.call))
            } else {
                entry.confirmations = 0
                tracked[id] = entry
            }
        }
        return events
    }
}

/// Links a detected call to the calendar event it belongs to, by join link.
public enum CallCalendarMatcher {
    public static func match(
        _ call: DetectedCall,
        intents: [AtlasCaptureScheduleIntent],
        nowMs: Int64,
        earlyMs: Int64 = 10 * 60_000,
        lateMs: Int64 = 15 * 60_000
    ) -> AtlasCaptureScheduleIntent? {
        let links = intents.map { intent in (intent, joinURLs(intent)) }
        if let code = call.meetingCode,
           let exact = links.first(where: { _, urls in
               urls.contains { $0.host == "meet.google.com" && $0.path.lowercased() == "/" + code }
           }) {
            return exact.0
        }
        let current = links.filter { intent, urls in
            intent.startMs - earlyMs <= nowMs && nowMs <= intent.endMs + lateMs
                && urls.contains { url in
                    guard let host = url.host?.lowercased() else { return false }
                    return call.platform.joinHosts.contains { host == $0 || host.hasSuffix("." + $0) }
                }
        }.map(\.0)
        // A Meet code that matches no event is a different call.
        if call.meetingCode != nil, call.platform == .googleMeet { return nil }
        return current.min { abs($0.startMs - nowMs) < abs($1.startMs - nowMs) }
    }

    private static func joinURLs(_ intent: AtlasCaptureScheduleIntent) -> [URL] {
        [intent.meetingURL, intent.location].compactMap { $0 }.flatMap { text -> [URL] in
            text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).compactMap { token in
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()\"'"))
                guard trimmed.lowercased().hasPrefix("http"), let url = URL(string: trimmed) else { return nil }
                return url
            }
        }
    }
}
