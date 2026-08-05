import AVFoundation
import Combine
import SwiftUI

@main
struct KokoroBooksApp: App {
    @StateObject private var settings = AppSettings()
    var body: some Scene {
        WindowGroup {
            Group {
                if settings.isConfigured {
                    RootTabView()
                } else {
                    NavigationStack { SettingsView() }
                }
            }
            .environmentObject(settings)
            .preferredColorScheme(appColorScheme(settings.appearance))
        }
    }
}

/// Map the stored appearance setting to a SwiftUI color scheme (nil = system).
func appColorScheme(_ s: String) -> ColorScheme? {
    switch s {
    case "light": return .light
    case "dark":  return .dark
    default:      return nil
    }
}

/// Light/Dark toggle shown top-right on every page.
struct ThemeToggleButton: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Button {
            settings.appearance = (settings.appearance == "dark") ? "light" : "dark"
        } label: {
            Image(systemName: settings.appearance == "dark" ? "sun.max.fill" : "moon.fill")
        }
    }
}

/// Three tabs: the folder library, downloaded books (offline-only), and the
/// "Continue listening" shelf.
struct RootTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            DownloadedView()
                .tabItem { Label("Downloaded", systemImage: "arrow.down.circle.fill") }
            StartedView()
                .tabItem { Label("Listening", systemImage: "headphones") }
        }
    }
}

/// Edits live in local @State and are only committed to AppSettings when the
/// user taps Connect (after a reachability/auth check). This avoids the trap
/// where typing one token character flips `isConfigured` and navigates away
/// mid-input, firing a request with an incomplete token.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Server") {
                TextField("http://192.168.178.172:8724", text: $baseURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("API token", text: $token)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text(checking ? "Connecting…" : "Connect")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(baseURL.isEmpty || token.isEmpty || checking)
            } footer: {
                Text("Same WiFi: use the Mac's LAN IP. From anywhere: the Tailscale name. The token is printed by the server on startup.")
            }
        }
        .navigationTitle("Settings")
        .onAppear { baseURL = settings.baseURL; token = settings.token }
    }

    private func connect() async {
        checking = true; error = nil
        defer { checking = false }
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let probe = URL(string: url + "/api/library") else {
            error = "Invalid server URL"; return
        }
        var req = URLRequest(url: probe, timeoutInterval: 8)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { error = "Token rejected (401). Check the API token."; return }
            if !(200...299).contains(code) { error = "Server error (\(code))."; return }
            // Only now commit — this flips isConfigured and shows the library.
            settings.baseURL = url
            settings.token = tok
            dismiss()
        } catch {
            self.error = "Can't reach the server. Check the URL and that the Mac is on."
        }
    }
}

/// Root: a folder browser starting at the library root.
struct LibraryView: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        NavigationStack { FolderView(folder: "", title: "Library") }
    }
}

/// One folder level: its subfolders (with recursive book counts) and the books
/// directly inside it. The search field queries ALL books globally, regardless
/// of the current folder.
struct FolderView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var downloads = DownloadManager.shared
    let folder: String
    let title: String

    @State private var subfolders: [LibraryFolder] = []
    @State private var books: [Book] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @State private var isOffline = false
    @AppStorage("voiceID") private var voiceID = 0

    private var api: APIClient { APIClient(settings: settings) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if isOffline {
                Section {
                    Label("Offline — showing downloaded books", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !searching, !subfolders.isEmpty {
                Section("Folders") {
                    ForEach(subfolders) { f in
                        NavigationLink(value: f) {
                            Label {
                                HStack {
                                    Text(f.name)
                                    Spacer()
                                    Text("\(f.count)").foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "folder.fill").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            if !books.isEmpty {
                Section(searching ? "Results" : (isOffline ? "Downloaded" : "Books")) {
                    ForEach(books) { book in
                        BookRow(book: book, showFolder: searching)
                            .environmentObject(settings)
                    }
                }
            }
            if !loading, subfolders.isEmpty, books.isEmpty {
                Text(searching ? "No matches" : (isOffline ? "No downloaded books" : "Empty folder"))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search all books")
        .navigationDestination(for: LibraryFolder.self) { f in
            FolderView(folder: f.path, title: f.name).environmentObject(settings)
        }
        .navigationDestination(for: Book.self) { book in
            PlayerView(book: book).environmentObject(settings)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { ThemeToggleButton() }
            if folder.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) { VoiceMenu() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .refreshable { await load() }
        .task(id: "\(query)|\(voiceID)") {
            await load()
            // Auto-poll every 30s so cacheStatus updates while server generates.
            // wrap in Task to allow `try await` inside the non-throwing .task closure.
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if !Task.isCancelled { await load() }
                }
            }
        }
        .overlay { if let e = error, !isOffline { Text(e).foregroundStyle(.red).padding() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {                       // debounce search-as-you-type
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
        do {
            let r = try await api.browse(folder: folder, q: q.isEmpty ? nil : q,
                                         voiceID: voiceID == 0 ? nil : voiceID)
            subfolders = r.subfolders
            books = r.books
            if UserDefaults.standard.object(forKey: "voiceID") == nil,
               let first = r.voices.first {
                UserDefaults.standard.set(first.id, forKey: "voiceID")
            }
            isOffline = false
            error = nil
        } catch let caught {
            // Offline fallback: show downloaded books from local manifest
            let offline = downloads.offlineBooks()
            if !offline.isEmpty && folder.isEmpty {
                let filtered: [Book]
                if q.isEmpty {
                    filtered = offline
                } else {
                    let lq = q.lowercased()
                    filtered = offline.filter {
                        $0.title.lowercased().contains(lq) ||
                        $0.author.lowercased().contains(lq)
                    }
                }
                subfolders = []
                books = filtered
                isOffline = true
                self.error = nil
            } else {
                isOffline = false
                self.error = "Load failed: \(caught)"
            }
        }
    }
}

/// Selects one of the five Kokoro US male voices exposed by the server. Voice
/// IDs are deliberately loaded from the API rather than assumed locally.
struct VoiceMenu: View {
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("voiceID") private var voiceID = 0
    @State private var voices: [Voice] = []

    private let supportedNames = ["Michael", "Adam", "Eric", "Liam", "Onyx"]
    private var api: APIClient { APIClient(settings: settings) }
    private var selectedName: String {
        voices.first(where: { $0.id == voiceID })?.name ?? "Voice"
    }

    var body: some View {
        Menu {
            Picker("Kokoro voice", selection: $voiceID) {
                ForEach(voices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
        } label: {
            Label(selectedName, systemImage: "waveform")
        }
        .accessibilityLabel("Kokoro voice: \(selectedName)")
        .task { await loadVoices() }
    }

    private func loadVoices() async {
        guard let response = try? await api.browse(voiceID: nil) else { return }
        let byName = Dictionary(uniqueKeysWithValues: response.voices.map { ($0.name, $0) })
        voices = supportedNames.compactMap { byName[$0] }
        if voiceID == 0 || !voices.contains(where: { $0.id == voiceID }),
           let preferred = voices.first(where: { $0.name == "Michael" }) ?? voices.first {
            voiceID = preferred.id
        }
    }
}

/// Shared row used by the library and the "Listening" shelf: cover, title,
/// status, offline badge, and a progress bar once the book is started.
/// Library row with two clearly-separated tap targets:
/// - Left: cover + title → opens Player (HLS stream)
/// - Right: download button → starts server conversion + streams MP3
struct BookRow: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("voiceID") private var voiceID = 0
    let book: Book
    var showFolder = false

    @State private var downloading = false
    @State private var downloadProgress: Double = 0
    @State private var lastError: String?

    private var api: APIClient { APIClient(settings: settings) }
    private var isDownloaded: Bool { downloads.isDownloaded(book.bookId) }

    var body: some View {
        HStack(spacing: 12) {
            // Left: Play
            NavigationLink(value: book) {
                rowCoverAndTitle
            }
            .buttonStyle(.plain)
            // Right: Download
            downloadButton
        }
        .listRowSeparator(.hidden)
    }

    // MARK: - Left (Play)

    @ViewBuilder private var rowCoverAndTitle: some View {
        HStack(spacing: 12) {
            AuthImage(url: api.absURL("/api/library/\(book.bookId)/cover"),
                      token: settings.token) { Color.gray.opacity(0.2) }
                .scaledToFill()
                .frame(width: 44, height: 60).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                statusBadge
                if let lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Right (Download)

    @ViewBuilder private var downloadButton: some View {
        if isDownloaded {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(role: .destructive) {
                    downloads.delete(book.bookId)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
            }
        } else if downloading {
            VStack(spacing: 2) {
                ProgressView(value: downloadProgress)
                    .frame(width: 60)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70)
        } else {
            Button {
                startDownload()
            } label: {
                Label("Herunterladen", systemImage: "arrow.down.circle.fill")
                    .font(.caption).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch book.cacheStatus {
            case "ready":   return ("Bereit", .green)
            case "partial": return ("Wird erstellt…", .orange)
            default:        return ("Noch nicht erstellt", .secondary)
            }
        }()
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(color)
            if book.positionS > 1 {
                Text("• fortsetzen").font(.caption2).foregroundStyle(.secondary)
            }
            if showFolder, !book.folder.isEmpty {
                Text("• \(book.folder)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: - Actions

    private func startDownload() {
        guard voiceID != 0 else {
            lastError = "Bitte zuerst eine Stimme wählen"
            return
        }
        downloading = true
        lastError = nil
        downloadProgress = 0
        Task {
            await streamMP3Download()
        }
    }

    @MainActor
    private func streamMP3Download() async {
        do {
            // 1. Start server conversion
            let resp = try await api.convert(
                bookID: book.bookId, voiceID: voiceID, fmt: "m4b")
            let jobID = resp.jobId
            // 2. Build authenticated URL request for the streaming MP3
            guard let url = api.absURL("/api/jobs/\(jobID)/mp3") else {
                throw APIError.badURL
            }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
            // 3. Stream-download to a temp file, reporting progress
            let (tempURL, _) = try await URLSession.shared.download(
                for: req, delegate: DownloadDelegate(bookID: book.bookId) { frac in
                    self.downloadProgress = frac
                })
            // 4. Move into DownloadManager's offline storage
            downloads.importDownloadedMP3(bookID: book.bookId, from: tempURL)
            downloading = false
        } catch {
            lastError = apiErrorText(error)
            downloading = false
        }
    }

    private func apiErrorText(_ e: Error) -> String {
        if let apiErr = e as? APIError {
            switch apiErr {
            case .badURL:    return "Ungültige URL"
            case .http(let c): return "Server Fehler \(c)"
            case .decode:    return "Datenfehler"
            }
        }
        return "Netzwerkfehler"
    }
}

/// Lightweight URLSessionDownloadDelegate for progress callbacks.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let bookID: String
    let onProgress: (Double) -> Void
    init(bookID: String, onProgress: @escaping (Double) -> Void) {
        self.bookID = bookID
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            // Growing file — progress is unknown, show indeterminate
            onProgress(0)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by the await in streamMP3Download
    }
}

/// "Continue listening": books with a saved position, newest first.
struct StartedView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("voiceID") private var voiceID = 0
    @State private var books: [Book] = []
    @State private var error: String?
    @State private var bookToDelete: Book?
    @State private var isOffline = false

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nothing started yet").font(.headline)
                        Text("Books you begin will appear here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        if isOffline {
                            Section {
                                Label("Offline — showing downloaded books", systemImage: "wifi.slash")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(books) { book in
                            if book.isUnavailable {
                                // Ghost entry: PDF not found on server — show greyed out
                                BookRow(book: book)
                                    .opacity(0.45)
                                    .overlay(alignment: .bottomLeading) {
                                        Text("PDF nicht gefunden")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .padding(.leading, 4)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            bookToDelete = book
                                        } label: { Label("Entfernen", systemImage: "trash") }
                                    }
                            } else {
                                BookRow(book: book)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            bookToDelete = book
                                        } label: { Label("Entfernen", systemImage: "trash") }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Listening")
            .navigationDestination(for: Book.self) { book in
                PlayerView(book: book).environmentObject(settings)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { ThemeToggleButton() }
                ToolbarItem(placement: .navigationBarTrailing) { VoiceMenu() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await load() }
            .task(id: voiceID) { await load() }
            .overlay { if let e = error { Text(e).foregroundStyle(.red).padding() } }
            .confirmationDialog(
                "\"\(bookToDelete?.title ?? "")\" wirklich aus der Liste entfernen?",
                isPresented: Binding(get: { bookToDelete != nil },
                                     set: { if !$0 { bookToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Entfernen", role: .destructive) {
                    if let b = bookToDelete { Task { await remove(b) } }
                }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }

    private func load() async {
        do {
            let v = UserDefaults.standard.integer(forKey: "voiceID")
            var serverBooks = try await api.started(voiceID: v == 0 ? nil : v)
            error = nil
            // Resync any locally stored progress that the server doesn't know about.
            // This recovers from a server-side SQLite reset or accidental delete.
            let serverIDs = Set(serverBooks.map { $0.bookId })
            let local = LocalProgressStore.shared.load()
            var resynced = false
            for (bookID, entry) in local where !serverIDs.contains(bookID) {
                guard entry.positionS > 1 else { continue }
                try? await api.putProgress(bookID: bookID,
                                           positionS: entry.positionS,
                                           durationS: entry.durationS,
                                           title: entry.title,
                                           author: entry.author)
                resynced = true
            }
            if resynced {
                serverBooks = try await api.started(voiceID: v == 0 ? nil : v)
            }
            books = serverBooks
            isOffline = false
        } catch let caught {
            // Offline fallback: show downloaded books with resumed progress
            let offline = downloads.offlineBooks()
            if !offline.isEmpty {
                books = offline
                isOffline = true
                self.error = nil
            } else {
                isOffline = false
                self.error = "Load failed: \(caught)"
            }
        }
    }

    /// Remove from "Listening": forget the server position, local backup, and
    /// any offline download. Called only after the user confirms the dialog.
    private func remove(_ book: Book) async {
        books.removeAll { $0.id == book.id }
        bookToDelete = nil
        LocalProgressStore.shared.remove(book.bookId)
        DownloadManager.shared.delete(book.bookId)
        try? await api.deleteProgress(bookID: book.bookId)
    }
}

/// "Downloaded" shelf: every book that has been saved for offline playback,
/// served straight from `DownloadManager.shared.offlineBooks()`. This view is
/// deliberately network-free — it works even with the server unreachable and
/// the Mac powered off, so it's the canonical entry point for offline audio.
struct DownloadedView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var books: [Book] = []

    private var totalBytes: Int64 { downloads.totalBytes }
    private var maxBytes: Int64 { downloads.maxLocalBytes }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("No downloads yet").font(.headline)
                        Text("Tap “Download for offline” on a converted book to listen without the server.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        Section {
                            ForEach(books) { book in
                                BookRow(book: book)
                                    .environmentObject(settings)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        DownloadManager.shared.delete(book.bookId)
                                        books = DownloadManager.shared.offlineBooks()
                                    } label: {
                                        Label("Delete download", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("\(books.count) book\(books.count == 1 ? "" : "s") downloaded")
                        }
                        Section {
                            HStack {
                                Text("\(formatBytes(totalBytes)) of \(formatBytes(maxBytes)) used")
                                Spacer()
                                ProgressView(value: maxBytes > 0
                                             ? Double(totalBytes) / Double(maxBytes)
                                             : 0)
                                    .frame(width: 100)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Downloaded")
            .navigationDestination(for: Book.self) { book in
                PlayerView(book: book).environmentObject(settings)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { ThemeToggleButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { reload() }
            .task { reload() }
        }
    }

    /// Read straight from disk. No `APIClient` call — the view must work
    /// fully offline.
    private func reload() {
        books = DownloadManager.shared.offlineBooks()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}

struct PlayerView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.colorScheme) private var scheme
    @AppStorage("voiceID") private var selectedVoiceID = 1
    let book: Book
    @StateObject private var vm: PlayerViewModelHolder = .init()
    @State private var tab = 0   // 0 = chapters, 1 = running text
    @State private var showRecap = false

    private var api: APIClient { APIClient(settings: settings) }

    var body: some View {
        VStack(spacing: 12) {
            // Now-playing bar: cover thumbnail + title/author (compact, so the
            // text/chapter area below stays large).
            HStack(spacing: 12) {
                AuthImage(url: api.absURL("/api/library/\(book.bookId)/cover"),
                          token: settings.token) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
                }
                .scaledToFill()
                .frame(width: 58, height: 82).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title).font(.headline).lineLimit(2)
                    Text(book.author).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let m = vm.model {
                ScrubberView(vm: m)
                if m.offline {
                    Label("Offline", systemImage: "arrow.down.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else if let st = m.status, st.state == "processing" {
                    Text("Generating \(st.doneChunks)/\(st.totalChunks)…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 40) {
                Button { vm.model?.seek(to: (vm.model?.currentTime ?? 0) - 15) } label:
                    { Image(systemName: "gobackward.15") }
                Button { vm.model?.isPlaying == true ? vm.model?.pause() : vm.model?.play() } label:
                    { Image(systemName: vm.model?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill")
                        .resizable().frame(width: 58, height: 58) }
                Button { vm.model?.seek(to: (vm.model?.currentTime ?? 0) + 30) } label:
                    { Image(systemName: "goforward.30") }
            }.font(.title)

            HStack(spacing: 28) {
                sleepTimerControl
                downloadControl
            }

            let hasText = !(vm.model?.transcript.isEmpty ?? true)
            if hasText {
                Picker("", selection: $tab) {
                    Text("Chapters").tag(0)
                    Text("Text").tag(1)
                }.pickerStyle(.segmented)
            }

            if tab == 1 && hasText, let m = vm.model {
                LyricsView(vm: m)
            } else if let m = vm.model, !m.chapters.isEmpty {
                chapterList(m)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(tint)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    vm.model?.pause()
                    showRecap = true
                } label: { Image(systemName: "text.bubble") }
            }
            ToolbarItem(placement: .navigationBarTrailing) { ThemeToggleButton() }
        }
        .sheet(isPresented: $showRecap) {
            RecapSheet(api: api, bookID: book.bookId,
                       positionS: vm.model?.currentTime ?? 0)
        }
        .onAppear { vm.configure(api: api, book: book) }
        .onDisappear { vm.model?.stop() }
    }

    /// Accent that keeps contrast in both themes: a deep blue on the light wash
    /// (the system light-blue was too pale), the bright blue in dark mode.
    private var tint: Color {
        scheme == .dark ? .blue : Color(red: 0.04, green: 0.28, blue: 0.62)
    }

    @ViewBuilder private func chapterList(_ m: PlayerViewModel) -> some View {
        let current = m.currentChapterIndex()
        List(m.chapters) { ch in
            let isCurrent = ch.index == current
            Button { m.seek(toChapter: ch) } label: {
                HStack {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption).foregroundStyle(.tint)
                    }
                    Text(ch.title)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(ch.startS == nil ? .secondary
                                         : (isCurrent ? tint : .primary))
                    Spacer()
                    if ch.startS == nil {
                        Image(systemName: "hourglass").foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(ch.startS == nil)
            .listRowBackground(isCurrent ? Color.primary.opacity(0.06) : nil)
        }
    }

    /// Sleep timer: 30 / 45 / 60 minutes, with the remaining time shown and a
    /// way to turn it off. Pauses playback when it elapses.
    @ViewBuilder private var sleepTimerControl: some View {
        let remaining = vm.model?.sleepRemaining
        Menu {
            Button("30 minutes") { vm.model?.startSleepTimer(minutes: 30) }
            Button("45 minutes") { vm.model?.startSleepTimer(minutes: 45) }
            Button("60 minutes") { vm.model?.startSleepTimer(minutes: 60) }
            if remaining != nil {
                Button("Turn off", role: .destructive) { vm.model?.cancelSleepTimer() }
            }
        } label: {
            Label(
                remaining.map { String(format: "Sleep in %d:%02d", $0 / 60, $0 % 60) } ?? "Sleep timer",
                systemImage: remaining != nil ? "moon.zzz.fill" : "moon.zzz"
            ).font(.footnote)
                .foregroundStyle(remaining != nil ? tint : .secondary)
        }
    }

    /// Offline-download affordance: download when the M4B is ready, show a
    /// progress ring while downloading, or a delete option once stored.
    @ViewBuilder private var downloadControl: some View {
        if downloads.isDownloaded(book.bookId) {
            Button(role: .destructive) { downloads.delete(book.bookId) } label: {
                Label("Entfernen", systemImage: "trash")
            }.font(.footnote)
        } else if let frac = downloads.progress[book.bookId] {
            HStack {
                ProgressView(value: frac).frame(width: 120)
                Text("\(Int(frac * 100))%").font(.caption)
            }
        } else if vm.model?.status?.hasM4b == true {
            Button { vm.model?.downloadForOffline() } label: {
                Label("Herunterladen", systemImage: "arrow.down.circle")
            }.font(.footnote)
        } else if book.cacheStatus == "partial" {
            Label("Generiert...", systemImage: "hourglass")
                .font(.caption2).foregroundStyle(.secondary)
        } else if book.cacheStatus == "none" || book.cacheStatus == "cleaned" {
            Button {
                Task {
                    do {
                        let resp = try await api.convert(
                            bookID: book.bookId,
                            voiceID: selectedVoiceID,
                            fmt: "m4b")
                        for try await s in jobStatusStream(jobID: resp.jobId) {
                            if s.hasM4b || s.state == "failed" { break }
                        }
                    } catch { /* silent retry */ }
                }
            } label: {
                Label("Herunterladen", systemImage: "arrow.down.circle")
            }.font(.footnote)
            .foregroundStyle(.orange)
        }
    }

    /// Polls job status every 3 s until hasM4b, done, or failed.
    @MainActor
    private func jobStatusStream(jobID: Int) -> AsyncStream<JobStatus> {
        AsyncStream { cont in
            Task {
                while !Task.isCancelled {
                    do {
                        let s = try await api.status(jobID: jobID)
                        cont.yield(s)
                        if s.hasM4b || s.state == "done" || s.state == "failed" {
                            cont.finish()
                            break
                        }
                    } catch {
                        cont.finish()
                        break
                    }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }
}

/// Playback position bar with elapsed / remaining time; drag to seek.
struct ScrubberView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var scrubbing = false
    @State private var value = 0.0

    var body: some View {
        let dur = max(vm.duration, 1)
        VStack(spacing: 2) {
            Slider(value: $value, in: 0...dur) { editing in
                scrubbing = editing
                if !editing { vm.seek(to: value) }
            }
            HStack {
                Text(hms(value))
                Spacer()
                Text("-" + hms(max(dur - value, 0)))
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .onAppear { value = vm.currentTime }
        .onChange(of: vm.currentTime) { t in if !scrubbing { value = t } }
    }
}

/// Format seconds as m:ss or h:mm:ss.
func hms(_ secs: Double) -> String {
    let s = max(Int(secs.rounded()), 0)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%d:%02d", m, sec)
}

/// Spotify-style running text: highlights the sentence being spoken, auto-scrolls
/// to it, and lets you tap any line to jump there.
struct LyricsView: View {
    @ObservedObject var vm: PlayerViewModel

    var body: some View {
        let currentID = vm.currentLineID()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.transcript) { line in
                        let isCurrent = line.id == currentID
                        Text(line.text)
                            .font(isCurrent ? .title3 : .body)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? Color.primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.seek(to: line.startS) }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 80)
            }
            .onChange(of: vm.currentTime) { _ in
                guard let id = vm.currentLineID() else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// "Previously on…" sheet: requests a recap of everything heard so far, shows
/// a spinner while it's generated, then displays the text and plays the audio
/// (in the book's voice). The book is paused by the caller while this is open.
struct RecapSheet: View {
    let api: APIClient
    let bookID: String
    let positionS: Double
    @Environment(\.dismiss) private var dismiss
    @State private var status: RecapStatus?
    @State private var failed: String?
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let st = status, st.state == "ready" {
                    ScrollView { Text(st.text ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else if let f = failed ?? status?.error, status?.state == "failed" || failed != nil {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.bubble").font(.largeTitle).foregroundStyle(.secondary)
                        Text(f).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Summarizing what you've heard…").foregroundStyle(.secondary)
                    }.padding(40)
                }
            }
            .navigationTitle("Previously on…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { player?.pause(); dismiss() }
                }
            }
        }
        .task { await run() }
        .onDisappear { player?.pause(); player = nil }
    }

    private func run() async {
        do {
            let id = try await api.startRecap(bookID: bookID, positionS: positionS)
            for _ in 0..<90 {                       // poll up to ~3 min
                let st = try await api.recapStatus(id)
                status = st
                if st.state == "ready" {
                    if let u = st.audioUrl { playAudio(u) }
                    return
                }
                if st.state == "failed" { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            failed = "Timed out generating the recap."
        } catch { failed = "Couldn't generate a recap." }
    }

    private func playAudio(_ path: String) {
        guard let url = api.absURL(path) else { return }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(api.settings.token)"]
        ])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        p.play()
    }
}

/// Bridges the @MainActor view model into a SwiftUI @StateObject lifecycle.
@MainActor final class PlayerViewModelHolder: ObservableObject {
    @Published var model: PlayerViewModel?
    func configure(api: APIClient, book: Book) {
        guard model == nil else { return }
        let m = PlayerViewModel(api: api, book: book)
        model = m
        m.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        m.start()
    }
    private var cancellables = Set<AnyCancellable>()
}



