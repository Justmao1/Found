import Foundation
import XCTest
@testable import Lost_Found

@MainActor
final class AppStoreTests: XCTestCase {
    func testTranscriptionOnlyUpdatesItsUnchangedFindSession() throws {
        let harness = StoreHarness()
        defer { harness.close() }
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        harness.store.query = "Original description"
        let visitor = harness.store.visitorRevision
        let server = harness.store.revision
        XCTAssertTrue(harness.store.acceptTranscription("  蓝色 backpack  ", replacing: "Original description",
                                                        visitorRevision: visitor, serverRevision: server))
        XCTAssertEqual(harness.store.query, "蓝色 backpack")
        XCTAssertFalse(harness.store.isSearching, "Visitor must confirm the description before searching")
        XCTAssertFalse(harness.store.acceptTranscription("Late text", replacing: "Original description",
                                                         visitorRevision: visitor, serverRevision: server))
        XCTAssertEqual(harness.store.query, "蓝色 backpack")
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        XCTAssertFalse(harness.store.acceptTranscription("Previous visitor", replacing: "",
                                                         visitorRevision: visitor, serverRevision: server))
        XCTAssertEqual(harness.store.query, "")
        let currentVisitor = harness.store.visitorRevision
        try harness.store.changeServer(to: "https://another.invalid")
        XCTAssertFalse(harness.store.acceptTranscription("Previous server", replacing: "",
                                                         visitorRevision: currentVisitor, serverRevision: server))
        XCTAssertEqual(harness.store.query, "")
    }

    func testVisitorSessionEndsWithNoPersonalStateAndKeepsInventoryAndServer() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = sampleItem()
        harness.respond { request in
            if request.url?.path == "/api/items", request.httpMethod == "POST" {
                return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false)))
            }
            if request.url?.path == "/api/search" {
                return .json(body: try JSONEncoder().encode(SearchResponse(matches: [SearchMatch(item: saved, reason: "Bottle")], searchedCount: 1, pendingCount: 0)))
            }
            if request.url?.path == "/api/items" {
                return .json(body: try JSONEncoder().encode(ItemListResponse(items: [saved], total: 5)))
            }
            return .json(body: try JSONEncoder().encode(AIStatus(configured: true)))
        }
        XCTAssertEqual(harness.store.selectedTab, .home)
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()
        harness.store.query = "Bottle"
        await harness.store.search()
        let originalServer = harness.store.serverAddress
        let originalRevision = harness.store.visitorRevision
        XCTAssertNotNil(harness.store.lastSaved)
        XCTAssertNotNil(harness.store.searchResult)

        XCTAssertTrue(harness.store.endVisitorSession())

        XCTAssertEqual(harness.store.selectedTab, .home)
        XCTAssertGreaterThan(harness.store.visitorRevision, originalRevision)
        XCTAssertEqual(harness.store.query, "")
        XCTAssertNil(harness.store.searchResult)
        XCTAssertNil(harness.store.searchError)
        XCTAssertNil(harness.store.lastSaved)
        XCTAssertNil(harness.store.photoData)
        XCTAssertEqual(harness.store.note, "")
        XCTAssertFalse(harness.store.reportNeedsStaff)
        XCTAssertEqual(harness.store.items.map(\.id), [saved.id])
        XCTAssertEqual(harness.store.total, 1)
        XCTAssertEqual(harness.store.serverAddress, originalServer)
        XCTAssertTrue(harness.store.connected)
    }

    func testEndingVisitorSessionClearsAnUnsubmittedPhotoAndNote() throws {
        let harness = StoreHarness()
        defer { harness.close() }
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.setPhoto(Data([1, 2]))
        harness.store.note = "Personal location"

        XCTAssertTrue(harness.store.endVisitorSession())

        XCTAssertNil(harness.store.photoData)
        XCTAssertNil(harness.store.submission)
        XCTAssertEqual(harness.store.note, "")
        XCTAssertFalse(harness.store.reportNeedsStaff)
    }

    func testSearchFromOldVisitorCannotShowResultsOrFinishNewVisitorsSearch() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let firstStarted = expectation(description: "Previous visitor search started")
        let secondStarted = expectation(description: "Current visitor search started")
        let pending = LockedValue<[StubURLProtocol]>([])
        harness.handle { transport in
            let count = pending.modify { $0.append(transport); return $0.count }
            (count == 1 ? firstStarted : secondStarted).fulfill()
        }
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        harness.store.query = "Previous visitor"
        let oldSearch = Task { await harness.store.search() }
        await fulfillment(of: [firstStarted], timeout: 3)
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        harness.store.query = "Current visitor"
        let newSearch = Task { await harness.store.search() }
        await fulfillment(of: [secondStarted], timeout: 3)

        let oldResult = SearchResponse(matches: [SearchMatch(item: sampleItem(id: "previous"), reason: "Old search")], searchedCount: 1, pendingCount: 0)
        pending.value[0].complete(.json(body: try JSONEncoder().encode(oldResult)))
        await oldSearch.value
        XCTAssertTrue(harness.store.isSearching)
        XCTAssertNil(harness.store.searchResult)
        XCTAssertNil(harness.store.searchError)
        XCTAssertEqual(harness.store.query, "Current visitor")

        let newResult = SearchResponse(matches: [SearchMatch(item: sampleItem(id: "current"), reason: "New search")], searchedCount: 1, pendingCount: 0)
        pending.value[1].complete(.json(body: try JSONEncoder().encode(newResult)))
        await newSearch.value
        XCTAssertFalse(harness.store.isSearching)
        XCTAssertEqual(harness.store.searchResult?.matches.first?.item.id, "current")
    }

    func testPhotoImportFromPreviousVisitorOrServerIsRejected() throws {
        let harness = StoreHarness()
        defer { harness.close() }
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        let previousVisitor = harness.store.visitorRevision
        let previousServer = harness.store.revision
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        XCTAssertFalse(harness.store.acceptPhoto(Data([1]), visitorRevision: previousVisitor, serverRevision: previousServer))
        XCTAssertNil(harness.store.photoData)
        let currentVisitor = harness.store.visitorRevision
        XCTAssertTrue(harness.store.acceptPhoto(Data([2]), visitorRevision: currentVisitor, serverRevision: previousServer))
        harness.store.note = "Old server note"
        harness.store.query = "Old server query"

        try harness.store.changeServer(to: "https://another.invalid")

        XCTAssertGreaterThan(harness.store.visitorRevision, currentVisitor)
        XCTAssertNil(harness.store.photoData)
        XCTAssertEqual(harness.store.note, "")
        XCTAssertEqual(harness.store.query, "")
        XCTAssertFalse(harness.store.acceptPhoto(Data([3]), visitorRevision: currentVisitor, serverRevision: previousServer))
        XCTAssertFalse(harness.store.acceptPhoto(Data([3]), visitorRevision: harness.store.visitorRevision, serverRevision: previousServer))
    }

    func testUncertainUploadIsHeldForStaffAndRetriesTheIdenticalBody() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let bodies = LockedValue<[Data]>([])
        harness.respond { request in
            let body = try readBody(request)
            let count = bodies.modify { $0.append(body); return $0.count }
            return count == 1
                ? .failure(URLError(.timedOut))
                : .json(body: try JSONEncoder().encode(SaveItemResponse(item: sampleItem(), duplicate: true)))
        }
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        let photo = Data([1, 2, 3])
        harness.store.setPhoto(photo)
        harness.store.note = "Note for staff"
        await harness.store.savePhoto()
        let submissionID = try XCTUnwrap(harness.store.submission?.requestID)
        let saveError = try XCTUnwrap(harness.store.saveError)
        XCTAssertFalse(harness.store.beginVisitorTask(.report))

        XCTAssertTrue(harness.store.endVisitorSession())

        XCTAssertTrue(harness.store.reportNeedsStaff)
        XCTAssertEqual(harness.store.selectedTab, .home)
        XCTAssertEqual(harness.store.photoData, photo)
        XCTAssertEqual(harness.store.note, "Note for staff")
        XCTAssertEqual(harness.store.saveError, saveError)
        XCTAssertEqual(harness.store.submission?.requestID, submissionID)
        XCTAssertFalse(harness.store.beginVisitorTask(.report))
        XCTAssertFalse(harness.store.acceptPhoto(Data([9]), visitorRevision: harness.store.visitorRevision, serverRevision: harness.store.revision))
        let blockedSave = await harness.store.savePhoto()
        XCTAssertNil(blockedSave)
        XCTAssertEqual(bodies.value.count, 1)
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        XCTAssertTrue(harness.store.reportNeedsStaff)
        XCTAssertTrue(harness.store.resumePendingReport())
        XCTAssertEqual(harness.store.selectedTab, .report)
        XCTAssertFalse(harness.store.reportNeedsStaff)

        await harness.store.savePhoto()

        XCTAssertEqual(bodies.value.count, 2)
        XCTAssertEqual(bodies.value.first, bodies.value.last)
        XCTAssertNil(harness.store.submission)
        XCTAssertFalse(harness.store.reportNeedsStaff)
        XCTAssertNotNil(harness.store.lastSaved)
    }

    func testClearingHeldReportRestoresVisitorReporting() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        harness.respond { _ in .failure(URLError(.timedOut)) }
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertTrue(harness.store.reportNeedsStaff)

        harness.store.clearDraft()

        XCTAssertFalse(harness.store.reportNeedsStaff)
        XCTAssertFalse(harness.store.resumePendingReport())
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
    }

    func testVisitorCannotEndOrExpireSessionDuringUploadAndCompletionRestartsIdleTime() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let started = expectation(description: "Upload started")
        let pending = LockedValue<StubURLProtocol?>(nil)
        harness.handle { transport in
            pending.modify { $0 = transport }
            started.fulfill()
        }
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.recordVisitorActivity(at: Date().addingTimeInterval(-200))
        harness.store.setPhoto(Data([1]))
        let visitor = harness.store.visitorRevision
        let save = Task { await harness.store.savePhoto() }
        await fulfillment(of: [started], timeout: 3)

        XCTAssertFalse(harness.store.endVisitorSession())
        XCTAssertFalse(harness.store.beginVisitorTask(.find))
        harness.store.checkVisitorInactivity(at: Date())
        XCTAssertNil(harness.store.idleSecondsRemaining)
        XCTAssertEqual(harness.store.visitorRevision, visitor)
        XCTAssertEqual(harness.store.selectedTab, .report)
        XCTAssertFalse(harness.store.acceptPhoto(Data([9]), visitorRevision: visitor, serverRevision: harness.store.revision))

        try XCTUnwrap(pending.value).complete(.failure(URLError(.timedOut)))
        _ = await save.value
        harness.store.checkVisitorInactivity(at: Date())
        XCTAssertNil(harness.store.idleSecondsRemaining)
        XCTAssertEqual(harness.store.selectedTab, .report)
        XCTAssertTrue(harness.store.endVisitorSession())
    }

    func testIdleWarningCanContinueAndEventuallyEndsTheVisitorSession() throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.setPhoto(Data([1]))
        harness.store.note = "Private note"
        harness.store.recordVisitorActivity(at: start)
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(119))
        XCTAssertNil(harness.store.idleSecondsRemaining)
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(120))
        XCTAssertEqual(harness.store.idleSecondsRemaining, 30)
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(137))
        XCTAssertEqual(harness.store.idleSecondsRemaining, 13)

        harness.store.recordVisitorActivity(at: start.addingTimeInterval(140))
        XCTAssertNil(harness.store.idleSecondsRemaining)
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(150))
        XCTAssertEqual(harness.store.selectedTab, .report)
        XCTAssertNotNil(harness.store.photoData)
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(290))

        XCTAssertEqual(harness.store.selectedTab, .home)
        XCTAssertNil(harness.store.idleSecondsRemaining)
        XCTAssertNil(harness.store.photoData)
        XCTAssertEqual(harness.store.note, "")
        let visitor = harness.store.visitorRevision
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(1_000))
        XCTAssertEqual(harness.store.visitorRevision, visitor)
        harness.store.selectedTab = .settings
        harness.store.checkVisitorInactivity(at: start.addingTimeInterval(2_000))
        XCTAssertEqual(harness.store.selectedTab, .settings)
        XCTAssertNil(harness.store.idleSecondsRemaining)
    }

    func testAcknowledgedSaveFinishesWithoutRequestingTheItemList() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let requests = LockedValue<[String]>([])
        let saved = sampleItem()
        harness.respond { request in
            requests.modify { $0.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")") }
            guard request.httpMethod == "POST" else { return .failure(URLError(.timedOut)) }
            return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false)))
        }
        harness.store.setPhoto(Data([1, 2, 3]))
        harness.store.note = "Bottle"

        let acknowledgement = await harness.store.savePhoto()

        XCTAssertEqual(requests.value, ["POST /api/items"])
        XCTAssertEqual(acknowledgement?.id, saved.id)
        XCTAssertFalse(harness.store.isSaving)
        XCTAssertTrue(harness.store.connected)
        XCTAssertEqual(harness.store.lastSaved?.id, saved.id)
        XCTAssertEqual(harness.store.items.map(\.id), [saved.id])
        XCTAssertEqual(harness.store.total, 1)
        XCTAssertNil(harness.store.listError)
        XCTAssertNil(harness.store.photoData)
        XCTAssertNil(harness.store.submission)
        XCTAssertEqual(harness.store.note, "")
    }

    func testDuplicateAcknowledgementDoesNotIncreaseKnownTotal() async throws {
        for itemAlreadyCached in [true, false] {
            let harness = StoreHarness()
            defer { harness.close() }
            let saved = sampleItem()
            let other = sampleItem(id: "other-item")
            harness.respond { request in
                if request.httpMethod == "POST" {
                    return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: true)))
                }
                if request.url?.path == "/api/items" {
                    let items = itemAlreadyCached ? [other, saved] : [other]
                    return .json(body: try JSONEncoder().encode(ItemListResponse(items: items, total: 10)))
                }
                return .json(body: try JSONEncoder().encode(AIStatus(configured: false)))
            }
            await harness.store.refresh()
            harness.store.setPhoto(Data([1]))

            await harness.store.savePhoto()

            XCTAssertEqual(harness.store.total, 10)
            XCTAssertEqual(harness.store.items.map(\.id), [saved.id, other.id])
            XCTAssertEqual(harness.store.lastSaved?.id, saved.id)
        }
    }

    func testNewAcknowledgementKeepsLatestOneHundredItemsAndIncrementsTotal() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let existing = (0..<100).map { sampleItem(id: "existing-\($0)") }
        let saved = sampleItem()
        harness.respond { request in
            if request.httpMethod == "POST" {
                return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false)))
            }
            if request.url?.path == "/api/items" {
                return .json(body: try JSONEncoder().encode(ItemListResponse(items: existing, total: 200)))
            }
            return .json(body: try JSONEncoder().encode(AIStatus(configured: false)))
        }
        await harness.store.refresh()
        harness.store.setPhoto(Data([1]))

        await harness.store.savePhoto()

        XCTAssertEqual(harness.store.total, 201)
        XCTAssertEqual(harness.store.items.count, 100)
        XCTAssertEqual(harness.store.items.first?.id, saved.id)
        XCTAssertEqual(harness.store.items.last?.id, existing[98].id)
    }

    func testFailedRefreshAfterAcknowledgedSavePreservesConfirmation() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = sampleItem()
        harness.respond { request in
            guard request.httpMethod == "POST" else { return .failure(URLError(.notConnectedToInternet)) }
            return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false)))
        }
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()

        await harness.store.refresh()

        XCTAssertEqual(harness.store.lastSaved?.id, saved.id)
        XCTAssertEqual(harness.store.items.first?.id, saved.id)
        XCTAssertEqual(harness.store.total, 1)
        XCTAssertNil(harness.store.saveError)
        XCTAssertNotNil(harness.store.listError)
        XCTAssertFalse(harness.store.connected)
        XCTAssertFalse(harness.store.isSaving)
    }

    func testSecondSaveWhileUploadingDoesNotStartAnotherRequest() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let requestStarted = expectation(description: "First save reached transport")
        let pending = LockedValue<StubURLProtocol?>(nil)
        let requestCount = LockedValue(0)
        harness.handle { transport in
            requestCount.modify { $0 += 1 }
            pending.modify { $0 = transport }
            requestStarted.fulfill()
        }
        harness.store.setPhoto(Data([1]))
        let firstSave = Task { await harness.store.savePhoto() }
        await fulfillment(of: [requestStarted], timeout: 3)

        let secondAcknowledgement = await harness.store.savePhoto()

        XCTAssertEqual(requestCount.value, 1)
        XCTAssertNil(secondAcknowledgement)
        XCTAssertTrue(harness.store.isSaving)
        try XCTUnwrap(pending.value).complete(.failure(URLError(.timedOut)))
        let firstAcknowledgement = await firstSave.value
        XCTAssertNil(firstAcknowledgement)
        XCTAssertFalse(harness.store.isSaving)
    }

    func testRefreshStartedBeforeSaveCannotOverwriteAcknowledgedItem() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let requestStarted = expectation(description: "Earlier refresh reached transport")
        let pendingRefresh = LockedValue<StubURLProtocol?>(nil)
        let saved = sampleItem()
        harness.handle { transport in
            if transport.request.httpMethod == "POST" {
                do {
                    transport.complete(.json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false))))
                } catch { transport.complete(.failure(error)) }
            } else {
                pendingRefresh.modify { $0 = transport }
                requestStarted.fulfill()
            }
        }
        let earlierRefresh = Task { await harness.store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 3)
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()

        let staleList = ItemListResponse(items: [], total: 0)
        try XCTUnwrap(pendingRefresh.value).complete(.json(body: JSONEncoder().encode(staleList)))
        await earlierRefresh.value

        XCTAssertEqual(harness.store.items.map(\.id), [saved.id])
        XCTAssertEqual(harness.store.total, 1)
        XCTAssertEqual(harness.store.lastSaved?.id, saved.id)
        XCTAssertTrue(harness.store.connected)
        XCTAssertFalse(harness.store.isRefreshing)
    }

    func testFailedSaveKeepsPhotoNoteAndSubmissionForRetry() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        harness.respond { request in
            .json(status: 503, body: Data(#"{"error":"Temporarily unavailable"}"#.utf8))
        }
        let photo = Data([1, 2, 3])
        harness.store.setPhoto(photo)
        harness.store.note = "Umbrella near the library"

        await harness.store.savePhoto()

        XCTAssertEqual(harness.store.photoData, photo)
        XCTAssertEqual(harness.store.note, "Umbrella near the library")
        XCTAssertEqual(harness.store.submission?.image, photo.base64EncodedString())
        XCTAssertEqual(harness.store.submission?.note, "Umbrella near the library")
        XCTAssertEqual(harness.store.saveError, "Temporarily unavailable")
        XCTAssertNil(harness.store.lastSaved)
        XCTAssertFalse(harness.store.isSaving)
    }

    func testRetrySendsIdenticalRequestBodyAndClearsDraftOnlyAfterSuccess() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let captured = LockedValue<[Data]>([])
        let saved = sampleItem()
        harness.respond { request in
            if request.httpMethod == "POST" {
                let body = try readBody(request)
                let count = captured.modify { bodies in bodies.append(body); return bodies.count }
                return count == 1
                    ? .json(status: 503, body: Data(#"{"error":"Retry later"}"#.utf8))
                    : .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: true)))
            }
            if request.url?.path == "/api/items" {
                return .json(body: try JSONEncoder().encode(ItemListResponse(items: [saved], total: 1)))
            }
            return .json(body: try JSONEncoder().encode(AIStatus(configured: false)))
        }
        let originalPhoto = Data([1, 2, 3])
        harness.store.setPhoto(originalPhoto)
        harness.store.note = "  Original note  "
        await harness.store.savePhoto()
        let pendingID = try XCTUnwrap(harness.store.submission?.requestID)
        XCTAssertNotNil(UUID(uuidString: pendingID))

        harness.store.note = "Edited after the request failed"
        harness.store.setPhoto(Data([8, 9]))
        XCTAssertEqual(harness.store.photoData, originalPhoto)
        await harness.store.savePhoto()

        let bodies = captured.value
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        let request = try JSONDecoder().decode(SaveItemRequest.self, from: XCTUnwrap(bodies.last))
        XCTAssertEqual(request.requestID, pendingID)
        XCTAssertEqual(request.note, "Original note")
        XCTAssertEqual(request.image, originalPhoto.base64EncodedString())
        XCTAssertNil(harness.store.photoData)
        XCTAssertNil(harness.store.submission)
        XCTAssertEqual(harness.store.note, "")
        XCTAssertEqual(harness.store.lastSaved?.id, saved.id)
        XCTAssertNil(harness.store.saveError)
        XCTAssertEqual(harness.store.total, 1)
    }

    func testPendingSubmissionBlocksServerChangeUntilDraftIsCleared() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        harness.respond { _ in .failure(URLError(.notConnectedToInternet)) }
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()
        let originalAddress = harness.store.serverAddress
        XCTAssertThrowsError(try harness.store.changeServer(to: "https://another.invalid")) { error in
            XCTAssertTrue(error is SettingsError)
        }
        XCTAssertEqual(harness.store.serverAddress, originalAddress)
        harness.store.clearDraft()
        XCTAssertNoThrow(try harness.store.changeServer(to: "https://another.invalid"))
        XCTAssertEqual(harness.store.serverAddress, "https://another.invalid")
    }

    func testSavingExistingServerAddressPreservesPendingSubmission() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        harness.respond { _ in .failure(URLError(.notConnectedToInternet)) }
        let photo = Data([1, 2, 3])
        harness.store.setPhoto(photo)
        harness.store.note = "Umbrella near the library"
        await harness.store.savePhoto()
        let pending = try XCTUnwrap(harness.store.submission)
        let originalAddress = harness.store.serverAddress
        let originalRevision = harness.store.revision

        XCTAssertNoThrow(try harness.store.changeServer(to: originalAddress))

        XCTAssertEqual(harness.store.serverAddress, originalAddress)
        XCTAssertEqual(harness.store.revision, originalRevision)
        XCTAssertEqual(harness.store.submission?.requestID, pending.requestID)
        XCTAssertEqual(harness.store.submission?.image, pending.image)
        XCTAssertEqual(harness.store.submission?.note, pending.note)
        XCTAssertEqual(harness.store.photoData, photo)
        XCTAssertEqual(harness.store.note, "Umbrella near the library")
    }

    func testChangingServerWhileSavingIsBlocked() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let requestStarted = expectation(description: "Save reached transport")
        let pending = LockedValue<StubURLProtocol?>(nil)
        harness.handle { transport in
            pending.modify { $0 = transport }
            requestStarted.fulfill()
        }
        harness.store.setPhoto(Data([1]))
        let save = Task { await harness.store.savePhoto() }
        await fulfillment(of: [requestStarted], timeout: 3)
        XCTAssertTrue(harness.store.isSaving)
        XCTAssertThrowsError(try harness.store.changeServer(to: "https://another.invalid"))
        harness.store.clearDraft()
        XCTAssertNotNil(harness.store.submission)
        try XCTUnwrap(pending.value).complete(.failure(URLError(.timedOut)))
        let acknowledgement = await save.value
        XCTAssertNil(acknowledgement)
        XCTAssertNotNil(harness.store.submission)
        XCTAssertFalse(harness.store.isSaving)
    }

    func testRefreshFromPreviousServerCannotPopulateNewServerState() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let requestStarted = expectation(description: "Refresh reached transport")
        let pending = LockedValue<StubURLProtocol?>(nil)
        harness.handle { transport in
            pending.modify { $0 = transport }
            requestStarted.fulfill()
        }
        let refresh = Task { await harness.store.refresh() }
        await fulfillment(of: [requestStarted], timeout: 3)
        try harness.store.changeServer(to: "https://new-server.invalid")
        let response = ItemListResponse(items: [sampleItem()], total: 1)
        try XCTUnwrap(pending.value).complete(.json(body: JSONEncoder().encode(response)))
        await refresh.value

        XCTAssertEqual(harness.store.serverAddress, "https://new-server.invalid")
        XCTAssertTrue(harness.store.items.isEmpty)
        XCTAssertEqual(harness.store.total, 0)
        XCTAssertFalse(harness.store.connected)
        XCTAssertFalse(harness.store.isRefreshing)
        XCTAssertNil(harness.store.listError)
    }

    func testSearchFromPreviousServerCannotPopulateNewServerState() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let requestStarted = expectation(description: "Search reached transport")
        let pending = LockedValue<StubURLProtocol?>(nil)
        harness.handle { transport in
            pending.modify { $0 = transport }
            requestStarted.fulfill()
        }
        harness.store.query = "green bottle"
        let search = Task { await harness.store.search() }
        await fulfillment(of: [requestStarted], timeout: 3)
        try harness.store.changeServer(to: "https://new-server.invalid")
        let response = SearchResponse(matches: [SearchMatch(item: sampleItem(), reason: "Green bottle")], searchedCount: 1, pendingCount: 0)
        try XCTUnwrap(pending.value).complete(.json(body: JSONEncoder().encode(response)))
        await search.value

        XCTAssertNil(harness.store.searchResult)
        XCTAssertNil(harness.store.searchError)
        XCTAssertFalse(harness.store.connected)
        XCTAssertFalse(harness.store.isSearching)
    }
}

private func sampleItem(id: String = "b24db87d-b0a7-4aa8-b447-7ba963a2b4dc") -> FoundItem {
    FoundItem(
        id: id, createdAt: "2026-10-20T08:00:00Z",
        note: "Bottle", imageURL: "/uploads/bottle.jpg", recognitionStatus: "disabled"
    )
}

@MainActor
private final class StoreHarness {
    let store: AppStore
    private let suite = "FoundNativeTests.\(UUID().uuidString)"
    private let host = "test-\(UUID().uuidString.lowercased()).invalid"
    private let defaults: UserDefaults
    private let session: URLSession

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://\(host)", forKey: "serverAddress")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        store = AppStore(defaults: defaults, session: session)
    }

    func handle(_ handler: @escaping (StubURLProtocol) -> Void) {
        StubURLProtocol.register(host: host, handler: handler)
    }

    func respond(_ response: @escaping (URLRequest) throws -> StubURLProtocol.Response) {
        handle { transport in
            do { transport.complete(try response(transport.request)) }
            catch { transport.complete(.failure(error)) }
        }
    }

    func close() {
        session.invalidateAndCancel()
        StubURLProtocol.unregister(host: host)
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { modify { $0 } }
    @discardableResult
    func modify<Result>(_ action: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return action(&storage)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case json(status: Int = 200, body: Data)
        case failure(Error)
    }
    private static let handlers = LockedValue<[String: (StubURLProtocol) -> Void]>([:])

    static func register(host: String, handler: @escaping (StubURLProtocol) -> Void) {
        handlers.modify { $0[host] = handler }
    }
    static func unregister(host: String) { handlers.modify { $0[host] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handlers.value[request.url?.host ?? ""] else {
            complete(.failure(URLError(.resourceUnavailable)))
            return
        }
        handler(self)
    }
    override func stopLoading() {}
    func complete(_ response: Response) {
        switch response {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .json(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private func readBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { return result }
        result.append(buffer, count: count)
    }
}
