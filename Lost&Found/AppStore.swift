import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    enum Tab: Hashable { case home, report, find, items, settings }
    enum DoorFeedbackState: Equatable { case manual, checking, open, closed, unavailable }
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
    private(set) var lockerStatus: LockerStatusResponse?
    private(set) var lockerOperation: LockerOperation?
    private(set) var lockerItem: FoundItem?
    private(set) var lockerError: String?
    private(set) var isLockerBusy = false
    private(set) var lockerNeedsStaff = false
    private(set) var storedItems: [FoundItem] = []
    private(set) var isDoorMonitoringActive = false
    private var doorReading: LockerDoor?
    private var doorReadingAt: Date?
    private var doorReadFailed = false
    private var doorFeedbackRequired = false
    @ObservationIgnored private var doorRefreshSequence = 0
    @ObservationIgnored private var pendingLocker: PendingLockerCommand?
    @ObservationIgnored private var lockerRefreshSequence = 0
    @ObservationIgnored private let lockerJournalURL: URL
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var lastVisitorActivity = Date()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, session: URLSession = .shared, lockerJournalURL: URL? = nil) {
        self.defaults = defaults
        self.session = session
        self.lockerJournalURL = lockerJournalURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Found/pending-locker.json")
        #if targetEnvironment(simulator)
        let fallback = "http://127.0.0.1:8080"
        #else
        let fallback = "https://work123.local:8443"
        #endif
        let saved = defaults.string(forKey: "serverAddress") ?? fallback
        serverAddress = (try? ServerAddress.parse(saved))?.absoluteString ?? fallback
        if let data = try? Data(contentsOf: self.lockerJournalURL),
           let command = try? JSONDecoder().decode(PendingLockerCommand.self, from: data) {
            pendingLocker = command
            lockerNeedsStaff = true
        }
    }

    var client: APIClient {
        // Only validated addresses enter this state.
        APIClient(baseURL: URL(string: serverAddress)!, session: session)
    }
    var hasPendingItems: Bool {
        items.contains { ["pending", "processing"].contains($0.recognitionStatus) }
    }
    var hasPendingLocker: Bool { pendingLocker != nil }
    var availableItems: [FoundItem] { lockerStatus?.enabled == false ? items : storedItems }
    var requiresDoorFeedback: Bool {
        guard let operation = lockerOperation else { return false }
        return doorFeedbackRequired || operation.door?.enabled == true || lockerStatus?.compartments.first {
            $0.id == operation.compartmentID
        }?.door?.enabled == true
    }

    func doorFeedbackState(for operation: LockerOperation, at date: Date = Date()) -> DoorFeedbackState {
        guard lockerOperation?.id == operation.id, requiresDoorFeedback else { return .manual }
        guard isDoorMonitoringActive else { return .checking }
        guard !doorReadFailed else { return .unavailable }
        guard let reading = doorReading, let received = doorReadingAt else { return .checking }
        guard date.timeIntervalSince(received) < 3 else { return .unavailable }
        switch reading.state {
        case .closed where reading.enabled && reading.error == nil: return .closed
        case .open where reading.enabled && reading.error == nil: return .open
        case .unknown where reading.enabled && reading.error == nil: return .checking
        default: return .unavailable
        }
    }

    func canCompleteLockerOperation(_ operation: LockerOperation, at date: Date = Date()) -> Bool {
        guard lockerOperation?.id == operation.id, operation.state == "awaiting_confirmation",
              !isLockerBusy, !lockerNeedsStaff else { return false }
        switch doorFeedbackState(for: operation, at: date) {
        case .manual, .closed: return true
        default: return false
        }
    }

    func setDoorMonitoringActive(_ active: Bool) {
        guard active != isDoorMonitoringActive else { return }
        isDoorMonitoringActive = active
        invalidateDoorReading()
    }

    /// The foreground clock also expires a reading while a slow request is still in flight.
    func expireDoorReading(at date: Date = Date()) {
        guard let received = doorReadingAt, date.timeIntervalSince(received) >= 3 else { return }
        doorReading = nil; doorReadingAt = nil; doorReadFailed = true
    }

    private func invalidateDoorReading() {
        doorRefreshSequence += 1
        doorReading = nil; doorReadingAt = nil; doorReadFailed = false
    }

    @discardableResult
    func beginVisitorTask(_ tab: Tab) -> Bool {
        guard !isSaving, !isLockerBusy,
              tab != .report || (!reportNeedsStaff && submission == nil && !hasPendingLocker) else { return false }
        guard endVisitorSession() else { return false }
        selectedTab = tab
        recordVisitorActivity()
        return true
    }

    @discardableResult
    func endVisitorSession() -> Bool {
        guard !isSaving, !isLockerBusy else { return false }
        invalidateDoorReading()
        doorFeedbackRequired = false
        lockerNeedsStaff = hasPendingLocker
        lockerOperation = nil; lockerItem = nil; lockerError = nil
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
        guard selectedTab != .home, selectedTab != .settings, !isSaving, !isLockerBusy else {
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
        guard !isSaving, !isLockerBusy, submission == nil, !hasPendingLocker else { throw SettingsError.pendingUpload }
        invalidateDoorReading()
        doorFeedbackRequired = false
        revision += 1
        visitorRevision += 1
        refreshSequence += 1
        serverAddress = url.absoluteString
        defaults.set(serverAddress, forKey: "serverAddress")
        items = []; total = 0; connected = false; aiConfigured = false
        isRefreshing = false; isSearching = false
        listError = nil; statusMessage = nil; searchResult = nil; searchError = nil
        lastSaved = nil; recognizing = []; recognitionErrors = [:]
        lockerStatus = nil; lockerOperation = nil; lockerItem = nil; lockerError = nil
        storedItems = []; lockerNeedsStaff = false; lockerRefreshSequence += 1
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
            if let saved = lastSaved, let refreshed = result.items.first(where: { $0.id == saved.id }) { lastSaved = refreshed }
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
            guard revision == currentRevision, sequence == refreshSequence, !Task.isCancelled else { return }
            await refreshLockers()
        } catch {
            guard revision == currentRevision, sequence == refreshSequence, !Task.isCancelled else { return }
            connected = false; listError = error.localizedDescription
            lockerRefreshSequence += 1; lockerStatus = nil; storedItems = []
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

    func refreshLockers() async {
        let server = revision
        lockerRefreshSequence += 1
        let sequence = lockerRefreshSequence
        let api = client
        do {
            let status = try await api.lockers()
            guard revision == server, sequence == lockerRefreshSequence, !Task.isCancelled else { return }
            // Availability must not wait for a second request that the view may cancel.
            lockerStatus = status; storedItems = []
            if let operation = lockerOperation,
               status.compartments.first(where: { $0.id == operation.compartmentID })?.door?.enabled == true {
                doorFeedbackRequired = true
            }
            await reconcileCompletedLockerRequest(server: server, sequence: sequence)
            guard revision == server, sequence == lockerRefreshSequence, !Task.isCancelled else { return }
            guard status.enabled else { return }
            do {
                let available = try await api.items(availableOnly: true).items
                guard revision == server, sequence == lockerRefreshSequence, !Task.isCancelled else { return }
                storedItems = available
            } catch {
                // The fresh compartment snapshot is still valid; old searchable items are not.
                guard revision == server, sequence == lockerRefreshSequence, !Task.isCancelled else { return }
                storedItems = []
            }
        } catch {
            guard revision == server, sequence == lockerRefreshSequence, !Task.isCancelled else { return }
            // Never advertise stale free slots while the locker API is unreachable.
            lockerStatus = nil; storedItems = []
        }
    }

    /// A request completed elsewhere must not keep the next visitor locked out.
    /// Confirm its exact identity with a GET; absence from the active list is not proof of completion.
    private func reconcileCompletedLockerRequest(server: Int, sequence: Int) async {
        guard !isLockerBusy, lockerNeedsStaff, let command = pendingLocker,
              command.serverAddress == serverAddress else { return }
        let visitor = visitorRevision
        do {
            let response = try await client.lockerOperation(id: command.request.requestID)
            guard revision == server, visitorRevision == visitor, sequence == lockerRefreshSequence,
                  !Task.isCancelled, !isLockerBusy, lockerNeedsStaff,
                  pendingLocker?.request.requestID == command.request.requestID else { return }
            try validateLockerResponse(response, expected: command.request)
            guard response.operation.state == "completed" else { return }
            pendingLocker = nil
            do { try persistLockerCommand() }
            catch { pendingLocker = command; return }
            lockerNeedsStaff = false
            lockerOperation = nil; lockerItem = nil; lockerError = nil
            invalidateDoorReading()
            doorFeedbackRequired = false
        } catch {
            // An unfinished, missing or unreachable request still needs explicit recovery.
        }
    }

    func beginDeposit(for item: FoundItem) async {
        guard selectedTab == .report, lastSaved?.id == item.id,
              item.recognition?.tags.isEmpty == false, item.status == "recorded",
              !Task.isCancelled else { return }
        await beginLockerOperation(item: item, kind: "deposit")
    }

    func beginRetrieval(for item: FoundItem) async {
        guard item.isStored, !Task.isCancelled else { return }
        await beginLockerOperation(item: item, kind: "retrieve")
    }

    private func beginLockerOperation(item: FoundItem, kind: String) async {
        guard !isLockerBusy, !hasPendingLocker, !lockerNeedsStaff else { return }
        guard lockerStatus?.enabled == true else {
            lockerError = "Locker service is unavailable. Please ask staff for help."
            return
        }
        let request = LockerOperationRequest(itemID: item.id, kind: kind)
        pendingLocker = PendingLockerCommand(serverAddress: serverAddress, request: request)
        do { try persistLockerCommand() } // Atomic file replacement completes before any network side effect.
        catch {
            pendingLocker = nil
            lockerError = "Could not save the locker request on this iPad. Please ask staff for help."
            return
        }
        lockerItem = item; lockerOperation = nil; lockerError = nil
        await sendPendingLockerCommand()
    }

    /// An explicit recovery action reuses the exact request identity; never called by polling.
    func retryLockerRequest() async {
        guard !isLockerBusy, hasPendingLocker else { return }
        await sendPendingLockerCommand()
    }

    private func sendPendingLockerCommand() async {
        guard let command = pendingLocker, command.serverAddress == serverAddress else {
            lockerError = "This locker request belongs to another server. Please ask staff for help."
            return
        }
        isLockerBusy = true; lockerError = nil
        defer { isLockerBusy = false; recordVisitorActivity() }
        do {
            let result = try await client.beginLockerOperation(command.request)
            try applyLockerResponse(result, expected: command.request)
        } catch {
            if case APIError.server(let code, _) = error, (400..<500).contains(code), code != 408 {
                // A rejected command has no effect. Committed/uncertain operations return state.
                let rejected = pendingLocker
                pendingLocker = nil
                do { try persistLockerCommand(); lockerNeedsStaff = false }
                catch { pendingLocker = rejected }
            }
            lockerError = error.localizedDescription
        }
        await refreshLockers()
    }

    /// Read-only recovery. A missing response never causes an automatic pulse.
    func refreshLockerOperation() async {
        guard !isLockerBusy, let command = pendingLocker,
              command.serverAddress == serverAddress else { return }
        isLockerBusy = true; lockerError = nil
        defer { isLockerBusy = false; recordVisitorActivity() }
        do {
            let response = try await client.lockerOperation(id: command.request.requestID)
            try applyLockerResponse(response, expected: command.request)
        } catch {
            lockerError = error.localizedDescription
        }
        await refreshLockers()
    }

    /// Poll the current visit only. This never submits a command or renews visitor activity.
    func monitorLockerDoor() async {
        let server = revision
        let visitor = visitorRevision
        let operationID = lockerOperation?.id
        while !Task.isCancelled, isDoorMonitoringActive, revision == server, visitorRevision == visitor,
              lockerOperation?.id == operationID, lockerOperation?.state == "awaiting_confirmation",
              requiresDoorFeedback, !lockerNeedsStaff {
            await refreshLockerDoor()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func refreshLockerDoor() async {
        guard isDoorMonitoringActive, !isLockerBusy, !lockerNeedsStaff, requiresDoorFeedback,
              let operation = lockerOperation, operation.state == "awaiting_confirmation",
              let command = pendingLocker, command.request.requestID == operation.id,
              command.serverAddress == serverAddress, !Task.isCancelled else { return }
        let server = revision
        let visitor = visitorRevision
        doorRefreshSequence += 1
        let sequence = doorRefreshSequence
        let requestedAt = Date()
        do {
            let response = try await client.lockerOperation(id: operation.id)
            guard revision == server, visitorRevision == visitor, sequence == doorRefreshSequence,
                  isDoorMonitoringActive, lockerOperation?.id == operation.id, !isLockerBusy,
                  !lockerNeedsStaff, !Task.isCancelled else { return }
            try validateLockerResponse(response, expected: command.request)
            if response.operation.state != "awaiting_confirmation" {
                try applyLockerResponse(response, expected: command.request)
                return
            }
            // Do not refresh inventory or mutate the operation journal on every sensor read.
            // A missing payload from a previously configured sensor must not enable manual completion.
            doorReading = response.operation.door
            doorReadingAt = requestedAt
            doorReadFailed = response.operation.door == nil
            expireDoorReading()
        } catch {
            guard revision == server, visitorRevision == visitor, sequence == doorRefreshSequence,
                  isDoorMonitoringActive, lockerOperation?.id == operation.id, !Task.isCancelled else { return }
            doorReading = nil; doorReadingAt = nil; doorReadFailed = true
        }
    }

    func completeLockerOperation() async {
        guard !isLockerBusy, !lockerNeedsStaff, let operation = lockerOperation,
              operation.state == "awaiting_confirmation", let command = pendingLocker,
              command.serverAddress == serverAddress, command.request.requestID == operation.id,
              canCompleteLockerOperation(operation) else { return }
        invalidateDoorReading()
        isLockerBusy = true; lockerError = nil
        defer { isLockerBusy = false; recordVisitorActivity() }
        do {
            let response = try await client.completeLockerOperation(id: operation.id)
            try applyLockerResponse(response, expected: command.request)
        } catch { lockerError = error.localizedDescription }
        await refreshLockers()
    }

    func resolveLockerOperation(_ operation: LockerOperation, outcome: String) async {
        guard !isLockerBusy else { return }
        isLockerBusy = true; lockerError = nil
        defer { isLockerBusy = false; recordVisitorActivity() }
        do {
            let response = try await client.resolveLockerOperation(id: operation.id, outcome: outcome)
            let expected = LockerOperationRequest(requestID: operation.id, itemID: operation.itemID, kind: operation.kind)
            try applyLockerResponse(response, expected: expected)
            // Staff reconciliation must not become a public visitor receipt.
            lockerOperation = nil; lockerItem = nil
        } catch { lockerError = error.localizedDescription }
        await refreshLockers()
    }

    private func validateLockerResponse(_ response: LockerOperationResponse, expected: LockerOperationRequest) throws {
        guard response.operation.id == expected.requestID, response.operation.itemID == expected.itemID,
              response.operation.kind == expected.kind, response.item.id == expected.itemID,
              ["01", "02", "03", "04"].contains(response.operation.compartmentID),
              ["actuating", "awaiting_confirmation", "completed", "uncertain"].contains(response.operation.state) else {
            throw APIError.invalidResponse
        }
    }

    private func applyLockerResponse(_ response: LockerOperationResponse, expected: LockerOperationRequest) throws {
        try validateLockerResponse(response, expected: expected)
        invalidateDoorReading()
        doorFeedbackRequired = response.operation.door?.enabled == true || lockerStatus?.compartments.first {
            $0.id == response.operation.compartmentID
        }?.door?.enabled == true || (lockerOperation?.id == response.operation.id && doorFeedbackRequired)
        lockerOperation = response.operation; lockerItem = response.item
        lockerError = response.operation.error
        refreshSequence += 1; isRefreshing = false
        lockerRefreshSequence += 1
        if let status = lockerStatus {
            let compartments = status.compartments.map { compartment in
                guard compartment.id == response.operation.compartmentID else { return compartment }
                // A historical acknowledgement must not release a compartment now used by someone else.
                if response.operation.state == "completed", let owner = compartment.itemID, owner != response.item.id {
                    return compartment
                }
                if response.item.compartmentID == compartment.id {
                    let state: String
                    switch response.item.status {
                    case "deposit_pending": state = "reserved"
                    case "stored": state = "occupied"
                    case "retrieval_pending": state = "retrieving"
                    case "recovery": state = "recovery"
                    default: return compartment
                    }
                    return LockerCompartment(id: compartment.id, state: state, itemID: response.item.id,
                                             door: response.operation.door ?? compartment.door)
                }
                if response.operation.state == "completed", response.item.compartmentID == nil,
                   ["recorded", "collected"].contains(response.item.status), compartment.itemID == response.item.id {
                    return LockerCompartment(id: compartment.id, state: "free",
                                             door: response.operation.door ?? compartment.door)
                }
                return compartment
            }
            var operations = status.operations.filter { $0.id != response.operation.id }
            if response.operation.state != "completed" { operations.append(response.operation) }
            lockerStatus = LockerStatusResponse(enabled: status.enabled, driver: status.driver,
                                                compartments: compartments, operations: operations)
        }
        if let index = items.firstIndex(where: { $0.id == response.item.id }) { items[index] = response.item }
        if lastSaved?.id == response.item.id { lastSaved = response.item }
        storedItems.removeAll { $0.id == response.item.id }
        if response.item.isStored { storedItems.insert(response.item, at: 0) }
        if let results = searchResult {
            searchResult = SearchResponse(matches: results.matches.filter { $0.id != response.item.id },
                                          searchedCount: results.searchedCount, pendingCount: results.pendingCount)
        }
        if response.operation.state == "completed", pendingLocker?.request.requestID == expected.requestID {
            let completed = pendingLocker
            pendingLocker = nil
            do { try persistLockerCommand(); lockerNeedsStaff = false }
            catch { pendingLocker = completed; throw error }
        }
    }

    private func persistLockerCommand() throws {
        if let pendingLocker {
            let data = try JSONEncoder().encode(pendingLocker)
            try FileManager.default.createDirectory(at: lockerJournalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: lockerJournalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: lockerJournalURL.path) {
            try FileManager.default.removeItem(at: lockerJournalURL)
        }
    }
}

private struct PendingLockerCommand: Codable {
    let serverAddress: String
    let request: LockerOperationRequest
}

enum SettingsError: LocalizedError {
    case pendingUpload
    var errorDescription: String? {
        "Finish your pending photo or locker operation before changing servers. Staff can check interrupted locker operations."
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
