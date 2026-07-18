import Foundation
import Combine

/// Offline downloads (Audible-style): a finished book's M4B is saved to the
/// device so it plays without the server and survives server-side cache
/// eviction. The listening position still syncs to the server, so deleting a
/// local copy never loses your place.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// book_id -> on-disk metadata for downloaded books.
    @Published private(set) var downloaded: [String: DownloadedBook] = [:]
    /// book_id -> 0...1 while a download is in flight.
    @Published private(set) var progress: [String: Double] = [:]

    /// Soft cap on local storage; oldest (by lastPlayed) is evicted past this.
    var maxLocalBytes: Int64 = 4 * 1024 * 1024 * 1024  // 4 GB

    private var tasks: [String: URLSessionDownloadTask] = [:]

    struct DownloadedBook: Codable {
        let bookID: String
        let title: String
        let author: String
        let sizeBytes: Int64
        var lastPlayed: Date
    }

    private init() { load() }

    // MARK: - Paths

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var manifestURL: URL { dir.appendingPathComponent("manifest.json") }
    func fileURL(_ bookID: String) -> URL { dir.appendingPathComponent("\(bookID).m4b") }
    func transcriptURL(_ bookID: String) -> URL {
        dir.appendingPathComponent("\(bookID).transcript.json")
    }

    /// The synced "lyrics" transcript saved alongside an offline download.
    func localTranscript(_ bookID: String) -> [TranscriptLine]? {
        guard let data = try? Data(contentsOf: transcriptURL(bookID)) else { return nil }
        return try? JSONDecoder().decode([TranscriptLine].self, from: data)
    }

    func isDownloaded(_ bookID: String) -> Bool {
        downloaded[bookID] != nil && FileManager.default.fileExists(atPath: fileURL(bookID).path)
    }

    var totalBytes: Int64 { downloaded.values.reduce(0) { $0 + $1.sizeBytes } }

    // MARK: - Download

    func download(book: Book, jobID: Int, api: APIClient) {
        guard !isDownloaded(book.bookId), tasks[book.bookId] == nil else { return }
        guard let url = api.absURL("/api/jobs/\(jobID)/audio") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(api.settings.token)", forHTTPHeaderField: "Authorization")

        progress[book.bookId] = 0
        let delegate = DownloadDelegate(bookID: book.bookId) { [weak self] frac in
            Task { @MainActor in self?.progress[book.bookId] = frac }
        } onFinish: { [weak self] tempURL in
            Task { @MainActor in self?.finish(book: book, tempURL: tempURL) }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: req)
        tasks[book.bookId] = task
        task.resume()

        // Save the synced transcript too, so the lyrics view works offline.
        Task {
            if let lines = try? await api.transcript(jobID: jobID),
               let data = try? JSONEncoder().encode(lines) {
                try? data.write(to: transcriptURL(book.bookId))
            }
        }
    }

    private func finish(book: Book, tempURL: URL?) {
        defer { tasks[book.bookId] = nil; progress[book.bookId] = nil }
        guard let tempURL else { return }
        let dest = fileURL(book.bookId)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tempURL, to: dest) }
        catch { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
        downloaded[book.bookId] = DownloadedBook(
            bookID: book.bookId, title: book.title, author: book.author,
            sizeBytes: size ?? 0, lastPlayed: Date())
        save()
        enforceBudget(keep: book.bookId)
    }

    // MARK: - Maintenance

    func markPlayed(_ bookID: String) {
        guard var b = downloaded[bookID] else { return }
        b.lastPlayed = Date(); downloaded[bookID] = b; save()
    }

    func delete(_ bookID: String) {
        try? FileManager.default.removeItem(at: fileURL(bookID))
        try? FileManager.default.removeItem(at: transcriptURL(bookID))
        downloaded[bookID] = nil; save()
    }

    /// Evict least-recently-played local books until under the soft cap.
    private func enforceBudget(keep: String?) {
        var total = totalBytes
        guard total > maxLocalBytes else { return }
        for b in downloaded.values.sorted(by: { $0.lastPlayed < $1.lastPlayed }) {
            if b.bookID == keep { continue }
            delete(b.bookID)
            total -= b.sizeBytes
            if total <= maxLocalBytes { break }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([DownloadedBook].self, from: data)
        else { return }
        downloaded = Dictionary(uniqueKeysWithValues: list.map { ($0.bookID, $0) })
    }

    private func save() {
        let list = Array(downloaded.values)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: manifestURL) }
    }
}

/// URLSession delegate bridging download progress + completion to the manager.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let bookID: String
    let onProgress: (Double) -> Void
    let onFinish: (URL?) -> Void

    init(bookID: String, onProgress: @escaping (Double) -> Void,
         onFinish: @escaping (URL?) -> Void) {
        self.bookID = bookID; self.onProgress = onProgress; self.onFinish = onFinish
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64,
                    totalBytesExpectedToWrite e: Int64) {
        if e > 0 { onProgress(Double(w) / Double(e)) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move synchronously out of the temp location before the closure returns.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4b")
        try? FileManager.default.moveItem(at: location, to: tmp)
        onFinish(tmp)
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        if err != nil { onFinish(nil) }
    }
}
