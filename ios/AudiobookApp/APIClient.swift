import Foundation

/// Server connection settings, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }
    /// "system" | "light" | "dark"
    @Published var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    /// Stable per-install id so the server knows which device wrote a position.
    let deviceID: String

    init() {
        baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? ""
        token = UserDefaults.standard.string(forKey: "token") ?? ""
        appearance = UserDefaults.standard.string(forKey: "appearance") ?? "dark"
        if let d = UserDefaults.standard.string(forKey: "deviceID") {
            deviceID = d
        } else {
            let d = UUID().uuidString
            UserDefaults.standard.set(d, forKey: "deviceID")
            deviceID = d
        }
    }

    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }
}

enum APIError: Error { case badURL, http(Int), decode }

/// Thin bearer-auth REST client.
struct APIClient {
    let settings: AppSettings

    private func request(_ path: String, method: String = "GET",
                         body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: settings.baseURL + path) else { throw APIError.badURL }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
            throw APIError.http(h.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decode }
    }

    /// Absolute URL for streaming/cover endpoints handed to AVPlayer / AsyncImage.
    /// Note: AVURLAsset needs the token as a header (see PlayerViewModel).
    func absURL(_ path: String) -> URL? { URL(string: settings.baseURL + path) }

    func browse(folder: String = "", q: String? = nil, voiceID: Int?,
                fmt: String = "m4b") async throws -> BrowseResponse {
        var items = [URLQueryItem(name: "fmt", value: fmt)]
        if !folder.isEmpty { items.append(.init(name: "folder", value: folder)) }
        if let q, !q.isEmpty { items.append(.init(name: "q", value: q)) }
        if let v = voiceID { items.append(.init(name: "voice_id", value: String(v))) }
        var comps = URLComponents()
        comps.queryItems = items
        let query = comps.percentEncodedQuery ?? ""
        return try await send(request("/api/library?" + query), as: BrowseResponse.self)
    }

    func started(voiceID: Int?) async throws -> [Book] {
        var path = "/api/started?fmt=m4b"
        if let v = voiceID { path += "&voice_id=\(v)" }
        return try await send(request(path), as: BooksResponse.self).books
    }

    func convert(bookID: String, voiceID: Int, fmt: String = "m4b") async throws -> ConvertResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "book_id": bookID, "voice_id": voiceID, "output_format": fmt])
        return try await send(request("/api/convert", method: "POST", body: body),
                              as: ConvertResponse.self)
    }

    func status(jobID: Int) async throws -> JobStatus {
        try await send(request("/api/jobs/\(jobID)/status"), as: JobStatus.self)
    }

    func chapters(jobID: Int) async throws -> [Chapter] {
        try await send(request("/api/jobs/\(jobID)/chapters"),
                       as: ChaptersResponse.self).chapters
    }

    func transcript(jobID: Int) async throws -> [TranscriptLine] {
        try await send(request("/api/jobs/\(jobID)/transcript"),
                       as: TranscriptResponse.self).lines
    }

    func startRecap(bookID: String, positionS: Double) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["position_s": positionS])
        return try await send(request("/api/library/\(bookID)/recap", method: "POST", body: body),
                              as: RecapStart.self).recapId
    }

    func recapStatus(_ recapID: String) async throws -> RecapStatus {
        try await send(request("/api/recap/\(recapID)"), as: RecapStatus.self)
    }

    func getProgress(bookID: String) async throws -> Progress {
        try await send(request("/api/library/\(bookID)/progress"), as: Progress.self)
    }

    func deleteProgress(bookID: String) async throws {
        _ = try await URLSession.shared.data(
            for: request("/api/library/\(bookID)/progress", method: "DELETE"))
    }

    func putProgress(bookID: String, positionS: Double, durationS: Double?,
                     title: String? = nil, author: String? = nil) async throws {
        var body: [String: Any] = [
            "position_s": positionS,
            "device_id": settings.deviceID,
            "updated_at": Date().timeIntervalSince1970,
        ]
        if let d = durationS { body["duration_s"] = d }
        if let t = title     { body["title"]  = t }
        if let a = author    { body["author"] = a }
        _ = try await URLSession.shared.data(
            for: request("/api/library/\(bookID)/progress", method: "PUT",
                         body: try JSONSerialization.data(withJSONObject: body)))
        LocalProgressStore.shared.save(
            bookID: bookID, title: title, author: author,
            positionS: positionS, durationS: durationS,
            updatedAt: Date().timeIntervalSince1970)
    }
}

// MARK: - Local progress backup (UserDefaults)

/// Mirrors every putProgress write to UserDefaults so the listening position
/// survives a server-side SQLite reset or accidental delete.
final class LocalProgressStore {
    static let shared = LocalProgressStore()
    private let key = "localProgress_v1"

    struct Entry: Codable {
        var bookId: String
        var title: String?
        var author: String?
        var positionS: Double
        var durationS: Double?
        var updatedAt: Double
    }

    func save(bookID: String, title: String?, author: String?,
              positionS: Double, durationS: Double?, updatedAt: Double) {
        var all = load()
        let existing = all[bookID]
        all[bookID] = Entry(
            bookId: bookID,
            title: title ?? existing?.title,
            author: author ?? existing?.author,
            positionS: positionS,
            durationS: durationS ?? existing?.durationS,
            updatedAt: updatedAt)
        persist(all)
    }

    func remove(_ bookID: String) {
        var all = load()
        all.removeValue(forKey: bookID)
        persist(all)
    }

    func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return dict
    }

    private func persist(_ dict: [String: Entry]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
