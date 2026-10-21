import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    enum Tab: Hashable { case home, report, find, items, settings }
    var selectedTab: Tab = .home
    private(set) var visitorRevision = 0
    private(set) var idleSecondsRemaining: Int?
    private(set) var reportNeedsStaff = false
    private(set) var serverAddress: String
    private(set) var items: [FoundItem] = []
    private(set) var total = 0
    private(set) var aiConfigured = false
    private(set) var connected = false
    private(set) var isRefreshing = false
    private(set) var listError: String?
    private(set) var statusMessage: String?
    private(set) var revision = 0
    var note = ""
    private(set) var photoData: Data?
    private(set) var submission: SaveItemRequest?
    private(set) var isSaving = false
    private(set) var saveError: String?
    private(set) var lastSaved: FoundItem?
    var query = ""
    private(set) var searchResult: SearchResponse?
    private(set) var searchError: String?
    private(set) var isSearching = false
    private(set) var recognizing: Set<String> = []
    private(set) var recognitionErrors: [String: String] = [:]
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var lastVisitorActivity = Date()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        #if targetEnvironment(simulator)
        let fallback = "http://127.0.0.1:8080"
        #else
        let fallback = "https://work123.local:8443"
        #endif
        let saved = defaults.string(forKey: "serverAddress") ?? fallback
        serverAddress = (try? ServerAddress.parse(saved))?.absoluteString ?? fallback
    }

    var client: APIClient {
        // Only validated addresses enter this state.
        APIClient(baseURL: URL(string: serverAddress)!, session: session)
    }
    var hasPendingItems: Bool {
        items.contains { ["pending", "processing"].contains($0.recognitionStatus) }
    }

    @discardableResult
    func beginVisitorTask(_ tab: Tab) -> Bool {
        guard !isSaving, tab != .report || (!reportNeedsStaff && submission == nil) else { return false }
        guard endVisitorSession() else { return false }
        selectedTab = tab
        recordVisitorActivity()
        return true
    }

    @discardableResult
    func endVisitorSession() -> Bool {
        guard !isSaving else { return false }
        visitorRevision += 1
        selectedTab = .home
        query = ""; searchResult = nil; searchError = nil; isSearching = false
        lastSaved = nil
        idleSecondsRemaining = nil
        if submission != nil {
            // A timed-out request may already be saved. Keep its idempotency key and
            // photo together for staff recovery, hidden from the next visitor.
            reportNeedsStaff = true
        } else {
            clearDraft()
        }
        return true
    }

    @discardableResult
    func resumePendingReport() -> Bool {
        guard !isSaving, submission != nil else { return false }
        guard endVisitorSession() else { return false }
        reportNeedsStaff = false
        selectedTab = .report
        recordVisitorActivity()
        return true
    }

    @discardableResult
    func acceptPhoto(_ data: Data, visitorRevision: Int, serverRevision: Int) -> Bool {
        guard self.visitorRevision == visitorRevision, revision == serverRevision,
              !reportNeedsStaff, !isSaving, submission == nil else { return false }
        setPhoto(data)
        recordVisitorActivity()
        return true
    }

    func recordVisitorActivity(at date: Date = Date()) {
        lastVisitorActivity = date
        idleSecondsRemaining = nil
    }

    func checkVisitorInactivity(at date: Date = Date()) {
        guard selectedTab != .home, selectedTab != .settings, !isSaving else {
            idleSecondsRemaining = nil
            return
        }
        let elapsed = date.timeIntervalSince(lastVisitorActivity)
        if elapsed >= 150 {
            endVisitorSession()
        } else if elapsed >= 120 {
            idleSecondsRemaining = Int(ceil(150 - elapsed))
        } else {
            idleSecondsRemaining = nil
        }
    }

    func changeServer(to address: String) throws {
        let url = try ServerAddress.parse(address)
        guard url.absoluteString != serverAddress else { return }
        guard !isSaving, submission == nil else { throw SettingsError.pendingUpload }
        revision += 1
        visitorRevision += 1
        refreshSequence += 1
        serverAddress = url.absoluteString
        defaults.set(serverAddress, forKey: "serverAddress")
        items = []; total = 0; connected = false; aiConfigured = false
        isRefreshing = false; isSearching = false
        listError = nil; statusMessage = nil; searchResult = nil; searchError = nil
        lastSaved = nil; recognizing = []; recognitionErrors = [:]
        query = ""
        clearDraft()
        recordVisitorActivity()
    }

    func refresh() async {
        let currentRevision = revision
        refreshSequence += 1
        let sequence = refreshSequence
        let api = client
        isRefreshing = true
        defer {
            if revision == currentRevision && sequence == refreshSequence { isRefreshing = false }
        }
        do {
            let result = try await api.items()
            guard revision == currentRevision, sequence == refreshSequence, !Task.isCancelled else { return }
            items = result.items; total = result.total; connected = true; listError = nil
            do {
                let status = try await api.aiStatus()
                guard revision == currentRevision, sequence == refreshSequence, !Task.isCancelled else { return }
                aiConfigured = status.configured
                statusMessage = status.configured ? nil : "Photos can be saved. AI tagging has not been enabled on this server."
            } catch {
                guard revision == currentRevision, sequence == refreshSequence, !Task.isCancelled else { return }
                aiConfigured = false
                statusMessage = "Photos can be saved. Could not check AI tagging; pull to refresh."
            }
        } catch {
            guard revision == currentRevision, sequence == refreshSequence, !Task.isCancelled else { return }
            connected = false; listError = error.localizedDescription
        }
    }

    func setPhoto(_ data: Data) {
        guard !isSaving, !reportNeedsStaff, submission == nil else { return }
        photoData = data; saveError = nil; lastSaved = nil
    }
    func clearDraft() {
        guard !isSaving else { return }
        photoData = nil; submission = nil; note = ""; saveError = nil
        reportNeedsStaff = false
    }
    @discardableResult
    func savePhoto() async -> FoundItem? {
        guard let photoData, !isSaving, !reportNeedsStaff else { return nil }
        if submission == nil {
            submission = SaveItemRequest(image: photoData.base64EncodedString(), note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let submission else { return nil }
        isSaving = true; saveError = nil
        defer {
            isSaving = false
            recordVisitorActivity()
        }
        do {
            let response = try await client.save(submission)
            lastSaved = response.item
            self.photoData = nil; self.submission = nil; note = ""; connected = true
            // A list request started before this acknowledgement may contain an older snapshot.
            refreshSequence += 1
            isRefreshing = false
            let alreadyListed = items.contains { $0.id == response.item.id }
            items.removeAll { $0.id == response.item.id }
            items.insert(response.item, at: 0)
            items = Array(items.prefix(100))
            total = max(total + (!response.duplicate && !alreadyListed ? 1 : 0), items.count)
            return response.item
        } catch {
            saveError = error.localizedDescription
            return nil
        }
    }
    func clearSearchResults() {
        guard !isSearching else { return }
        searchResult = nil; searchError = nil
    }

    @discardableResult
    func acceptTranscription(_ text: String, replacing previousQuery: String,
                             visitorRevision: Int, serverRevision: Int) -> Bool {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.visitorRevision == visitorRevision, revision == serverRevision,
              selectedTab == .find, !isSearching, query == previousQuery,
              !description.isEmpty, description.unicodeScalars.count <= 500 else { return false }
        query = description
        clearSearchResults()
        recordVisitorActivity()
        return true
    }
    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 500, !isSearching else { return }
        let currentRevision = revision
        let currentVisitor = visitorRevision
        let api = client
        isSearching = true; searchError = nil; searchResult = nil
        defer {
            if revision == currentRevision, visitorRevision == currentVisitor { isSearching = false }
        }
        do {
            let result = try await api.search(query: text)
            guard revision == currentRevision, visitorRevision == currentVisitor, !Task.isCancelled else { return }
            searchResult = result; connected = true
        } catch {
            guard revision == currentRevision, visitorRevision == currentVisitor, !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }
    func retryRecognition(for item: FoundItem) async {
        guard !recognizing.contains(item.id), aiConfigured else { return }
        let currentRevision = revision
        let api = client
        recognizing.insert(item.id); recognitionErrors[item.id] = nil
        defer { if revision == currentRevision { recognizing.remove(item.id) } }
        do { _ = try await api.recognize(id: item.id) }
        catch {
            guard revision == currentRevision, !Task.isCancelled else { return }
            recognitionErrors[item.id] = error.localizedDescription
        }
        guard revision == currentRevision, !Task.isCancelled else { return }
        await refresh()
    }
}

enum SettingsError: LocalizedError {
    case pendingUpload
    var errorDescription: String? {
        "Finish retrying your photo draft, or clear it in Report, before changing servers."
    }
}

extension FoundItem {
    var title: String { recognition?.tags.first ?? (note.isEmpty ? "Found item" : note) }
    var isPending: Bool { ["pending", "processing"].contains(recognitionStatus) }
    var dateLabel: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? createdAt
    }
}

func limitedText(_ text: String, to count: Int) -> String {
    // Match the Python API's Unicode code-point limits, including emoji sequences.
    String(String.UnicodeScalarView(text.unicodeScalars.prefix(count)))
}
