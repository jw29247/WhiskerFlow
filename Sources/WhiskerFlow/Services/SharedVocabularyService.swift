import Foundation
import Observation
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Fetches the agency-managed vocabulary glossary so client names and jargon
/// spell correctly for everyone without per-user setup.
///
/// The glossary is read-only and the payload is the same JSON shape as a local
/// `Vocabulary` (`{ "rules": [ { "find": …, "replaceWith": … } ] }`). The last
/// good copy is cached to disk so it keeps working offline. This only ever
/// performs an HTTPS GET to the configured URL — no transcript or user data is sent.
///
/// Every fetch is tagged with a monotonically increasing `generation`. Pointing
/// at a new URL (or turning the feature off) bumps the generation and cancels any
/// in-flight fetch, and a fetch only commits its result if its generation is still
/// current — so a slow response can never resurrect a superseded or disabled glossary.
@MainActor
@Observable
final class SharedVocabularyService {
    static let agencyURLString = "https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/shared-vocabulary.json"
    enum Status: Equatable {
        case idle
        case loading
        case loaded(count: Int, at: Date)
        case failed(String)
    }

    private(set) var rules: [VocabularyRule] = []
    private(set) var status: Status = .idle

    @ObservationIgnored private var urlString = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?

    var vocabulary: Vocabulary { Vocabulary(rules: rules) }

    init(session: URLSession = .shared, cacheURL: URL = SharedVocabularyService.defaultCacheURL) {
        self.session = session
        self.cacheURL = cacheURL
        loadInitialVocabulary()
    }

    deinit {
        fetchTask?.cancel()
        periodicTask?.cancel()
    }

    /// Point the service at a URL. Returns `true` if the URL changed (and a fetch
    /// was started). An empty URL turns the feature off and clears the cache.
    @discardableResult
    func configure(urlString newValue: String) -> Bool {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != urlString else { return false }
        urlString = trimmed
        if trimmed.isEmpty {
            generation &+= 1          // supersede any in-flight fetch
            fetchTask?.cancel()
            fetchTask = nil
            rules = []
            status = .idle
            try? FileManager.default.removeItem(at: cacheURL)
            return true
        }
        startFetch()
        return true
    }

    func configureAgencyLibrary() {
        _ = configure(urlString: Self.agencyURLString)
    }

    /// Re-fetch the current URL, superseding any in-flight fetch.
    func refresh() {
        guard !urlString.isEmpty else { return }
        startFetch()
    }

    /// Re-fetch on a slow cadence. The first fetch comes from `configure`, so this
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

    private func startFetch() {
        generation &+= 1
        let myGeneration = generation
        let requested = urlString
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.performFetch(generation: myGeneration, urlString: requested)
        }
    }

    private func performFetch(generation myGeneration: Int, urlString requested: String) async {
        guard let url = URL(string: requested), url.scheme?.lowercased() == "https" else {
            if myGeneration == generation { status = .failed("Glossary URL must start with https://") }
            return
        }
        if myGeneration == generation { status = .loading }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            // Bail if a newer configure/refresh superseded this fetch while it ran.
            guard myGeneration == generation else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let vocab = try AgencyVocabularyPolicy.decode(data)
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
            // leaves state to the fetch that replaced it. Otherwise surface the
            // error but keep the last good rules so dictation still benefits.
            guard myGeneration == generation else { return }
            status = .failed(error.localizedDescription)
            DiagnosticsService.capture(
                error: error,
                category: "glossary",
                code: String((error as NSError).code)
            )
        }
    }

    private func loadInitialVocabulary() {
        if let cache = try? Data(contentsOf: cacheURL),
           let vocabulary = try? AgencyVocabularyPolicy.decode(cache) {
            let modified = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            rules = vocabulary.rules
            status = .loaded(count: rules.count, at: modified)
            return
        }

        guard let seedURL = Bundle.module.url(
            forResource: "shared-vocabulary",
            withExtension: "json"
        ), let seed = try? Data(contentsOf: seedURL),
           let vocabulary = try? AgencyVocabularyPolicy.decode(seed) else { return }
        let modified = (try? seedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        rules = vocabulary.rules
        status = .loaded(count: rules.count, at: modified)
    }

    nonisolated static var defaultCacheURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhiskerFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("shared-vocabulary.json")
    }
}
