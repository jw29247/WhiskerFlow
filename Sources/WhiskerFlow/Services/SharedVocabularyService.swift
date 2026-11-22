import Foundation
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Fetches the agency-managed vocabulary glossary from Atlas so client names
/// and jargon spell correctly for everyone without per-user setup.
///
/// The glossary is read-only and the payload is the same JSON shape as a local
/// `Vocabulary` (`{ "rules": [ { "find": …, "replaceWith": … } ] }`). The last
/// good copy is cached to disk so it keeps working offline or when the token
/// can't be read for a moment. It names clients, so an explicit sign-out
/// deletes it (`signOut()`).
/// The request is authorised by the Atlas device token and carries no
/// arguments, so no transcript or user data is sent. Signed out, nothing is
/// requested; any failure keeps the last good rules.
///
/// Every fetch is tagged with a monotonically increasing `generation`. A newer
/// fetch (a refresh, a sign-in or a reconnect) bumps the generation and cancels
/// any in-flight fetch, and a fetch only commits its result if its generation is
/// still current, so a slow response can never resurrect a superseded glossary
/// or one fetched with a token that has since been replaced.
@MainActor
@Observable
final class SharedVocabularyService {
    enum Status: Equatable {
        case idle
        case loading
        case loaded(count: Int, at: Date)
        case failed(String)
    }

    private(set) var rules: [VocabularyRule] = []
    private(set) var status: Status = .idle

    @ObservationIgnored private var isStarted = false
    /// The token the latest fetch used, so a sign-in, reconnect or sign-out is
    /// noticed and a replaced token is never used again.
    @ObservationIgnored private var fetchedToken: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let client: () -> GlossaryAtlasClient?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?

    var vocabulary: Vocabulary { Vocabulary(rules: rules) }
    var isRefreshingPeriodically: Bool { periodicTask != nil }

    /// `client` returns nil while signed out. It is read at the start of every
    /// fetch, so it always reflects the current token.
    init(
        client: @escaping () -> GlossaryAtlasClient? = { nil },
        cacheURL: URL = SharedVocabularyService.defaultCacheURL
    ) {
        self.client = client
        self.cacheURL = cacheURL
        loadInitialVocabulary()
    }

    deinit {
        fetchTask?.cancel()
        periodicTask?.cancel()
    }

    /// Fetch the agency glossary now (if signed in) and on every later refresh.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        startFetch()
    }

    /// Re-fetch, superseding any in-flight fetch.
    func refresh() {
        guard isStarted else { return }
        startFetch()
    }

    /// Call when the Atlas sign-in may have changed. A new token (sign-in or
    /// reconnect) fetches straight away; a sign-out supersedes any fetch still
    /// using the old token.
    func credentialsChanged() {
        guard isStarted, client()?.token != fetchedToken else { return }
        startFetch()
    }

    /// Sign-out. Stops refreshing, drops any fetch in flight and deletes the
    /// copy downloaded from Atlas, leaving the glossary bundled with the app,
    /// as on an install that has never signed in. A sign-in fetches again
    /// through `credentialsChanged()`; restart the cadence with
    /// `startPeriodicRefresh`.
    func signOut() {
        generation &+= 1
        fetchTask?.cancel()
        fetchTask = nil
        periodicTask?.cancel()
        periodicTask = nil
        fetchedToken = nil
        do {
            try FileManager.default.removeItem(at: cacheURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was downloaded.
        } catch {
            DiagnosticsService.capture(error: error, category: "storage", code: String((error as NSError).code))
        }
        rules = []
        status = .idle
        loadInitialVocabulary()
    }

    /// Re-fetch on a slow cadence. The first fetch comes from `start`, so this
    /// sleeps before its first pass to avoid a duplicate launch fetch.
    func startPeriodicRefresh(interval: TimeInterval = 4 * 60 * 60) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                self?.refresh()
            }
        }
    }

    /// Waits for the fetch in flight, if any. Lets tests observe a fetch's outcome.
    func waitForCurrentFetch() async {
        await fetchTask?.value
    }

    private func startFetch() {
        generation &+= 1
        let myGeneration = generation
        fetchTask?.cancel()
        fetchTask = nil
        guard let client = client() else {
            // Signed out: request nothing, keep the cached rules, show no error.
            fetchedToken = nil
            if status == .loading { status = .idle }
            return
        }
        fetchedToken = client.token
        fetchTask = Task { [weak self] in
            await self?.performFetch(generation: myGeneration, client: client)
        }
    }

    private func performFetch(generation myGeneration: Int, client: GlossaryAtlasClient) async {
        if myGeneration == generation { status = .loading }
        do {
            let data = try await client.fetch()
            // Bail if a newer fetch, sign-in or sign-out superseded this one while it ran.
            guard myGeneration == generation else { return }
            let vocab = try ingest(data, source: "remote")
            guard myGeneration == generation else { return }
            rules = vocab.rules
            status = .loaded(count: rules.count, at: Date())
            do {
                try data.write(to: cacheURL, options: .atomic)
            } catch {
                DiagnosticsService.capture(
                    error: error,
                    category: "storage",
                    code: String((error as NSError).code)
                )
            }
        } catch {
            // A superseded/cancelled fetch (newer generation) stays silent and
            // leaves state to the fetch that replaced it. Otherwise record the
            // error but keep the last good rules (and their cache) so dictation
            // still benefits.
            guard myGeneration == generation else { return }
            status = .failed(error.localizedDescription)
            let clientError = error as? GlossaryClientError
            guard clientError?.isReportable ?? true else { return }
            DiagnosticsService.capture(
                error: error,
                category: "glossary",
                code: clientError?.diagnosticCode ?? String((error as NSError).code)
            )
        }
    }

    /// The sanitizer silently discards any rule that would rewrite everyday speech.
    /// The glossary is hand-maintained and served live from Atlas, so a drop has
    /// to be reported: otherwise the maintainer sees the rule "live" in Atlas
    /// while it never applies on a single machine.
    private func ingest(_ data: Data, source: String) throws -> Vocabulary {
        let report = try AgencyVocabularyPolicy.decodeReport(data)
        if report.droppedRuleCount > 0 {
            DiagnosticsService.breadcrumb(
                category: "glossary",
                metadata: [
                    "source": source,
                    "dropped_rules": String(report.droppedRuleCount),
                    "kept_rules": String(report.vocabulary.rules.count)
                ]
            )
            DiagnosticsService.capture(
                error: CocoaError(.fileReadCorruptFile),
                category: "glossary",
                code: "rules_dropped"
            )
        }
        return report.vocabulary
    }

    private func loadInitialVocabulary() {
        if let cache = try? Data(contentsOf: cacheURL),
           let vocabulary = try? ingest(cache, source: "cache") {
            let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            rules = vocabulary.rules
            status = .loaded(count: rules.count, at: modified)
            return
        }

        // The resource bundle name is fixed by SwiftPM, so a rename or a packaging
        // change silently ships an empty glossary unless the miss is reported.
        guard let resourcesURL = Bundle.main.resourceURL else {
            DiagnosticsService.capture(
                error: CocoaError(.fileNoSuchFile),
                category: "glossary",
                code: "seed_missing"
            )
            return
        }
        let seedURL = resourcesURL
            .appendingPathComponent("WhiskerFlow_WhiskerFlow.bundle", isDirectory: true)
            .appendingPathComponent("shared-vocabulary.json")
        guard let seed = try? Data(contentsOf: seedURL) else {
            DiagnosticsService.capture(
                error: CocoaError(.fileNoSuchFile),
                category: "glossary",
                code: "seed_missing"
            )
            return
        }
        guard let vocabulary = try? ingest(seed, source: "seed") else {
            DiagnosticsService.capture(
                error: CocoaError(.fileReadCorruptFile),
                category: "glossary",
                code: "seed_invalid"
            )
            return
        }
        let modified = (try? seedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        rules = vocabulary.rules
        status = .loaded(count: rules.count, at: modified)
    }

    nonisolated static var defaultCacheURL: URL {
        let root = StorageLocations.applicationSupportRootOrTemporary()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("shared-vocabulary.json")
    }
}
