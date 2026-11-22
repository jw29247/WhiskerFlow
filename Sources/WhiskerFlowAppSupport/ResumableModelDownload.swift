import Foundation

/// Sends one HTTP request and hands back the response head, then each body
/// chunk in order. Throwing from either callback stops the transfer.
public protocol ModelDownloadTransport: Sendable {
    func send(_ request: URLRequest,
              response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
              data: @escaping @Sendable (Data) throws -> Void) async throws
}

public enum ResumableModelDownloadError: Error, Equatable {
    case badResponse(Int)
    /// The server reports a different size from the pinned one.
    case unexpectedSize
    /// The server's file differs from the one the partial download came from.
    case remoteChanged
    /// The connection closed before the whole file arrived.
    case incomplete
    case verificationFailed
}

/// Downloads one pinned file with HTTP range requests, so a dropped connection,
/// a quit or a sleep continues from the bytes already on disk.
///
/// The partial file sits beside the destination as `<name>.partial`, with a
/// `<name>.partial.json` record of the source, size and server validators.
/// It is only resumed when that record still matches, and the server must
/// confirm the same file (ETag, Last-Modified and Content-Range total) before
/// new bytes are appended. Anything else is discarded and restarted from zero.
/// The finished file is verified before it is moved into place, so a partial
/// file is never mistaken for an installed one.
public final class ResumableModelDownload: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var url: String
        var byteCount: Int64
        var etag: String?
        var lastModified: String?
    }

    public let source: URL
    public let byteCount: Int64
    public let destination: URL
    private let transport: ModelDownloadTransport
    private let retryDelays: [TimeInterval]
    private let pause: @Sendable (TimeInterval) async throws -> Void
    private let lock = NSLock()
    private var discardRequested = false

    public init(source: URL, byteCount: Int64, destination: URL, transport: ModelDownloadTransport,
                retryDelays: [TimeInterval] = [2, 5, 15, 30, 60],
                pause: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.source = source
        self.byteCount = byteCount
        self.destination = destination
        self.transport = transport
        self.retryDelays = retryDelays
        self.pause = pause
    }

    public var partialFile: URL { destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial") }
    var recordFile: URL { destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial.json") }

    /// Bytes a resumed download would keep, or 0 when nothing matching is on disk.
    public var resumableBytes: Int64 {
        guard let record = loadRecord(), record.url == source.absoluteString, record.byteCount == byteCount,
              let size = try? partialFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, Int64(size) <= byteCount else { return 0 }
        return Int64(size)
    }

    public var resumableFraction: Double { byteCount > 0 ? Double(resumableBytes) / Double(byteCount) : 0 }

    /// Removes the partial file and its record.
    public func discardPartial() {
        try? FileManager.default.removeItem(at: partialFile)
        try? FileManager.default.removeItem(at: recordFile)
    }

    /// Call before cancelling the task running `install`: the partial file is
    /// removed once the transfer has stopped. Without it, cancelling keeps the
    /// partial file so a later download resumes.
    public func requestDiscard() {
        lock.lock()
        discardRequested = true
        lock.unlock()
    }

    private var shouldDiscard: Bool {
        lock.lock()
        defer { lock.unlock() }
        return discardRequested
    }

    /// Downloads (resuming when possible), verifies and moves the file to
    /// `destination`. `progress` starts at the resumed fraction.
    /// `verifying` is called once all bytes have arrived, before `verify`.
    public func install(verify: @escaping @Sendable (URL) throws -> Void,
                        verifying: @escaping @Sendable () async -> Void = {},
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await fetch(progress: progress)
            await verifying()
            let file = partialFile
            // Hashing gigabytes is slow: keep it off the caller's priority.
            let check = Task.detached(priority: .utility) { try verify(file) }
            do {
                try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                discardPartial()
                throw ResumableModelDownloadError.verificationFailed
            }
            try Task.checkCancellation()
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: partialFile)
            } else {
                try manager.moveItem(at: partialFile, to: destination)
            }
            try? manager.removeItem(at: recordFile)
        } catch {
            if shouldDiscard { discardPartial() }
            throw error
        }
    }

    /// Fetches every byte into the partial file, retrying transient network
    /// failures from the bytes already written.
    func fetch(progress: @escaping @Sendable (Double) -> Void) async throws {
        var failures = 0
        var restart = false
        while true {
            try Task.checkCancellation()
            let before = resumableBytes
            do {
                try await attempt(restart: restart, progress: progress)
                return
            } catch ResumableModelDownloadError.remoteChanged where !restart {
                // Never stitch two different files together: start again once.
                discardPartial()
                restart = true
                continue
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard Self.isTransient(error) else { throw error }
                restart = false
                // A transfer that made progress earns a fresh set of retries.
                if resumableBytes > before { failures = 0 }
                guard failures < retryDelays.count else { throw error }
                try await pause(retryDelays[failures])
                failures += 1
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? ResumableModelDownloadError { return error == .incomplete }
        guard let error = error as? URLError else { return false }
        return [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected,
                .secureConnectionFailed].contains(error.code)
    }

    private func attempt(restart: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let record = restart ? nil : loadRecord()
        let offset = restart ? 0 : resumableBytes
        if offset == 0 { discardPartial() }
        if offset == byteCount { progress(1); return }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        // Offsets and the pinned size count the stored bytes, so the server
        // must not compress the body on the way.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            // A strong ETag (or the date) makes a changed file come back whole.
            if let etag = record?.etag, !etag.hasPrefix("W/") {
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            } else if let date = record?.lastModified {
                request.setValue(date, forHTTPHeaderField: "If-Range")
            }
        }
        let sink = Sink(download: self, record: record, offset: offset, progress: progress)
        defer { sink.close() }
        try await transport.send(request, response: { try sink.begin($0) }, data: { try sink.write($0) })
        try sink.finish()
    }

    fileprivate func loadRecord() -> Record? {
        guard let data = try? Data(contentsOf: recordFile) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    fileprivate func saveRecord(_ record: Record) throws {
        try FileManager.default.createDirectory(at: recordFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordFile, options: .atomic)
    }
}

/// Writes one response into the partial file. The transport calls it serially.
private final class Sink: @unchecked Sendable {
    private unowned let download: ResumableModelDownload
    private let record: ResumableModelDownload.Record?
    private let resumeOffset: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var reported: Double = -1

    init(download: ResumableModelDownload, record: ResumableModelDownload.Record?, offset: Int64,
         progress: @escaping @Sendable (Double) -> Void) {
        self.download = download
        self.record = record
        self.resumeOffset = offset
        self.progress = progress
    }

    func begin(_ response: HTTPURLResponse) throws {
        lock.lock()
        defer { lock.unlock() }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified")
        let start: Int64
        switch response.statusCode {
        case 206 where resumeOffset > 0:
            guard let range = Self.contentRange(response.value(forHTTPHeaderField: "Content-Range")),
                  range.start == resumeOffset, range.total == download.byteCount else {
                throw ResumableModelDownloadError.remoteChanged
            }
            if let old = record?.etag, let etag, old != etag { throw ResumableModelDownloadError.remoteChanged }
            if let old = record?.lastModified, let lastModified, old != lastModified { throw ResumableModelDownloadError.remoteChanged }
            start = resumeOffset
        case 200:
            if response.expectedContentLength >= 0, response.expectedContentLength != download.byteCount {
                throw ResumableModelDownloadError.unexpectedSize
            }
            start = 0
        case 416:
            throw ResumableModelDownloadError.remoteChanged
        default:
            throw ResumableModelDownloadError.badResponse(response.statusCode)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: download.partialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if start == 0 {
            // A whole response replaces whatever was there (the server ignored
            // the range or the file changed); its record is written first.
            try? manager.removeItem(at: download.partialFile)
        }
        try download.saveRecord(.init(url: download.source.absoluteString, byteCount: download.byteCount,
                                      etag: etag ?? (start > 0 ? record?.etag : nil),
                                      lastModified: lastModified ?? (start > 0 ? record?.lastModified : nil)))
        if !manager.fileExists(atPath: download.partialFile.path) {
            guard manager.createFile(atPath: download.partialFile.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: download.partialFile)
        try handle.truncate(atOffset: UInt64(start))
        try handle.seekToEnd()
        self.handle = handle
        written = start
        report()
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw ResumableModelDownloadError.badResponse(0) }
        guard written + Int64(data.count) <= download.byteCount else { throw ResumableModelDownloadError.unexpectedSize }
        try handle.write(contentsOf: data)
        written += Int64(data.count)
        report()
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle?.synchronize()
        guard handle != nil, written == download.byteCount else { throw ResumableModelDownloadError.incomplete }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    /// About a thousand updates for the whole file, not one per network chunk.
    private func report() {
        let fraction = download.byteCount > 0 ? Double(written) / Double(download.byteCount) : 0
        guard fraction - reported >= 0.001 || (fraction == 1 && reported < 1) else { return }
        reported = fraction
        progress(fraction)
    }

    /// `bytes 100-199/1000` → (100, 1000).
    static func contentRange(_ value: String?) -> (start: Int64, total: Int64)? {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let start = parts[0].split(separator: "-").first.flatMap({ Int64($0) }),
              let total = Int64(parts[1]) else { return nil }
        return (start, total)
    }
}

/// The real transport. An ephemeral session keeps nothing in caches or cookies.
public final class URLSessionModelDownloadTransport: ModelDownloadTransport {
    public init() {}

    public func send(_ request: URLRequest,
                     response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                     data: @escaping @Sendable (Data) throws -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = TransferDelegate(response: response, data: data)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
}

private final class TransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onResponse: @Sendable (HTTPURLResponse) throws -> Void
    private let onData: @Sendable (Data) throws -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(response: @escaping @Sendable (HTTPURLResponse) throws -> Void, data: @escaping @Sendable (Data) throws -> Void) {
        onResponse = response
        onData = data
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            try onResponse(response)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do { try onData(data) } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}
