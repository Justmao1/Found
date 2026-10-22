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
    private let journal = FileManager.default.temporaryDirectory.appendingPathComponent("FoundLockerTest-\(UUID().uuidString)/pending.json")

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://\(host)", forKey: "serverAddress")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        store = AppStore(defaults: defaults, session: session, lockerJournalURL: journal)
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

    func relaunch() -> AppStore { AppStore(defaults: defaults, session: session, lockerJournalURL: journal) }

    func blockLockerJournal() throws {
        // A file where the journal directory belongs simulates unavailable durable storage.
        try Data([0]).write(to: journal.deletingLastPathComponent())
    }

    func close() {
        session.invalidateAndCancel()
        StubURLProtocol.unregister(host: host)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: journal.deletingLastPathComponent())
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

@MainActor
final class LockerStoreTests: XCTestCase {
    private let itemID = "b24db87d-b0a7-4aa8-b447-7ba963a2b4dc"

    private func item(status: String = "recorded", tagged: Bool = true) -> FoundItem {
        FoundItem(id: itemID, createdAt: "2026-10-22T08:00:00Z", note: "Bottle",
                  imageURL: "/images/\(itemID)", status: status,
                  recognition: tagged ? Recognition(tags: ["Water bottle", "Blue"]) : nil,
                  recognitionStatus: tagged ? "complete" : "processing",
                  compartmentID: status == "recorded" ? nil : "01")
    }

    private func status(first: LockerCompartment? = nil, operations: [LockerOperation] = []) -> LockerStatusResponse {
        LockerStatusResponse(enabled: true, driver: "simulated",
                             compartments: ["01", "02", "03", "04"].map {
                                 $0 == "01" ? first ?? LockerCompartment(id: $0, state: "free")
                                     : LockerCompartment(id: $0, state: "free")
                             }, operations: operations)
    }

    private func response(for command: LockerOperationRequest, state: String = "awaiting_confirmation",
                          door: LockerDoor? = nil) -> LockerOperationResponse {
        let storedStatus = command.kind == "deposit" ? "stored" : "collected"
        let pendingStatus = command.kind == "deposit" ? "deposit_pending" : "retrieval_pending"
        return LockerOperationResponse(
            operation: LockerOperation(id: command.requestID, kind: command.kind, itemID: command.itemID,
                                       compartmentID: "01", state: state, door: door),
            item: item(status: state == "completed" ? storedStatus : pendingStatus))
    }

    private func beginDoorRetrieval(_ harness: StoreHarness, door: LockerDoor,
                                   includeOperationDoor: Bool = true) async throws -> LockerOperation {
        let occupied = status(first: LockerCompartment(id: "01", state: "occupied", itemID: itemID, door: door))
        let buildResponse: (LockerOperationRequest) -> LockerOperationResponse = { [self] in
            response(for: $0, door: includeOperationDoor ? door : nil)
        }
        harness.respond { request in
            if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(occupied)) }
            if request.url!.path == "/api/locker-operations" {
                let command = try JSONDecoder().decode(LockerOperationRequest.self, from: readBody(request))
                return .json(body: try JSONEncoder().encode(buildResponse(command)))
            }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }
        await harness.store.refreshLockers()
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        harness.store.setDoorMonitoringActive(true)
        await harness.store.beginRetrieval(for: item(status: "stored"))
        return try XCTUnwrap(harness.store.lockerOperation)
    }

    func testOpenDoorPollingNeverPostsRefreshesInventoryOrKeepsTheVisitorAlive() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let door = LockerDoor(enabled: true, gpio: 12, pin: 32, state: .open, level: 1)
        let operation = try await beginDoorRetrieval(harness, door: door)
        let reply = LockerOperationResponse(operation: operation, item: item(status: "retrieval_pending"))
        let requests = LockedValue<[URLRequest]>([])
        harness.respond { request in
            requests.modify { $0.append(request) }
            return .json(body: try JSONEncoder().encode(reply))
        }
        harness.store.recordVisitorActivity(at: Date().addingTimeInterval(-151))
        XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .checking)
        await harness.store.refreshLockerDoor()
        XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .open)
        XCTAssertFalse(harness.store.isLockerBusy)
        XCTAssertFalse(harness.store.canCompleteLockerOperation(operation))
        await harness.store.completeLockerOperation()
        XCTAssertEqual(requests.value.count, 1)
        XCTAssertEqual(requests.value.first?.httpMethod, "GET")
        XCTAssertEqual(requests.value.first?.url?.path, "/api/locker-operations/\(operation.id)")
        harness.store.checkVisitorInactivity()
        XCTAssertEqual(harness.store.selectedTab, .home, "Sensor reads must not keep a visitor session alive")
    }

    func testClosedDoorStillNeedsConfirmationAndExpiredOrFailedReadBlocksIt() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let door = LockerDoor(enabled: true, gpio: 12, pin: 32, state: .closed, level: 0)
        let operation = try await beginDoorRetrieval(harness, door: door)
        let reply = LockerOperationResponse(operation: operation, item: item(status: "retrieval_pending"))
        let reads = LockedValue(0)
        harness.respond { request in
            XCTAssertEqual(request.httpMethod, "GET")
            reads.modify { $0 += 1 }
            return .json(body: try JSONEncoder().encode(reply))
        }
        await harness.store.refreshLockerDoor()
        XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .closed)
        XCTAssertTrue(harness.store.canCompleteLockerOperation(operation))
        XCTAssertTrue(harness.store.hasPendingLocker, "Closing a door alone must never mark an item collected")
        XCTAssertEqual(harness.store.lockerOperation?.state, "awaiting_confirmation")
        XCTAssertFalse(harness.store.canCompleteLockerOperation(operation, at: Date().addingTimeInterval(4)))
        harness.store.expireDoorReading(at: Date().addingTimeInterval(4))
        XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .unavailable)
        await harness.store.completeLockerOperation()
        XCTAssertEqual(reads.value, 1)
        await harness.store.refreshLockerDoor()
        XCTAssertTrue(harness.store.canCompleteLockerOperation(operation))
        harness.respond { _ in .failure(URLError(.notConnectedToInternet)) }
        await harness.store.refreshLockerDoor()
        XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .unavailable)
        XCTAssertFalse(harness.store.canCompleteLockerOperation(operation))
    }

    func testConfiguredDoorCannotFallBackToManualWhenItsPayloadDisappears() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let door = LockerDoor(enabled: true, gpio: 12, pin: 32, state: .closed, level: 0)
        let operation = try await beginDoorRetrieval(harness, door: door, includeOperationDoor: false)
        XCTAssertTrue(harness.store.requiresDoorFeedback)
        let reply = LockerOperationResponse(operation: operation, item: item(status: "retrieval_pending"))
        harness.respond { _ in .json(body: try JSONEncoder().encode(reply)) }
        await harness.store.refreshLockerDoor()
        XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .unavailable)
        XCTAssertFalse(harness.store.canCompleteLockerOperation(operation))
        harness.respond { _ in .failure(URLError(.notConnectedToInternet)) }
        await harness.store.refreshLockers()
        XCTAssertNil(harness.store.lockerStatus)
        XCTAssertTrue(harness.store.requiresDoorFeedback)
        XCTAssertFalse(harness.store.canCompleteLockerOperation(operation))
    }

    func testBackgroundOrSessionResetRejectsAnInFlightClosedReading() async throws {
        for resetSession in [false, true] {
            let harness = StoreHarness()
            defer { harness.close() }
            let door = LockerDoor(enabled: true, gpio: 12, pin: 32, state: .closed, level: 0)
            let operation = try await beginDoorRetrieval(harness, door: door)
            let reply = LockerOperationResponse(operation: operation, item: item(status: "retrieval_pending"))
            let started = expectation(description: "Door read started")
            let pending = LockedValue<StubURLProtocol?>(nil)
            harness.handle { transport in pending.modify { $0 = transport }; started.fulfill() }
            let reading = Task { await harness.store.refreshLockerDoor() }
            await fulfillment(of: [started], timeout: 3)
            XCTAssertFalse(harness.store.isLockerBusy)
            if resetSession { XCTAssertTrue(harness.store.endVisitorSession()) }
            else { harness.store.setDoorMonitoringActive(false) }
            try XCTUnwrap(pending.value).complete(.json(body: JSONEncoder().encode(reply)))
            await reading.value
            XCTAssertFalse(harness.store.canCompleteLockerOperation(operation))
            if resetSession { XCTAssertNil(harness.store.lockerOperation) }
            else {
                harness.store.setDoorMonitoringActive(true)
                XCTAssertEqual(harness.store.doorFeedbackState(for: operation), .checking)
            }
        }
    }

    func testDoorPollingLoopCancelsWithoutAnotherRequestOrBusyState() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let operation = try await beginDoorRetrieval(harness, door: LockerDoor(enabled: true, state: .open))
        let started = expectation(description: "Polling loop read started")
        let reads = LockedValue(0)
        harness.handle { transport in
            reads.modify { $0 += 1 }
            XCTAssertEqual(transport.request.httpMethod, "GET")
            started.fulfill()
        }
        let polling = Task { await harness.store.monitorLockerDoor() }
        await fulfillment(of: [started], timeout: 3)
        polling.cancel()
        await polling.value
        XCTAssertEqual(reads.value, 1)
        XCTAssertFalse(harness.store.isLockerBusy)
        XCTAssertFalse(harness.store.canCompleteLockerOperation(operation))
    }

    func testDepositWaitsForRecognitionAndDuplicateCallsCannotOpenAgain() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = item()
        let lockerStatus = status()
        let bodies = LockedValue<[Data]>([])
        let operation = LockedValue<LockerOperationRequest?>(nil)
        let responseBuilder: (LockerOperationRequest, String) -> LockerOperationResponse = { [self] command, state in
            response(for: command, state: state)
        }
        harness.respond { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/api/lockers"):
                return .json(body: try JSONEncoder().encode(lockerStatus))
            case ("POST", "/api/items"):
                return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false)))
            case ("POST", "/api/locker-operations"):
                let data = try readBody(request)
                bodies.modify { $0.append(data) }
                let command = try JSONDecoder().decode(LockerOperationRequest.self, from: data)
                operation.modify { $0 = command }
                return .json(body: try JSONEncoder().encode(responseBuilder(command, "awaiting_confirmation")))
            default:
                if request.url!.path.hasSuffix("/complete") {
                    return .json(body: try JSONEncoder().encode(responseBuilder(operation.value!, "completed")))
                }
                return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
            }
        }
        await harness.store.refreshLockers()
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()
        await harness.store.beginDeposit(for: item(tagged: false))
        XCTAssertTrue(bodies.value.isEmpty)
        await harness.store.beginDeposit(for: saved)
        await harness.store.beginDeposit(for: saved)
        XCTAssertEqual(bodies.value.count, 1)
        XCTAssertTrue(harness.store.hasPendingLocker)
        XCTAssertEqual(harness.store.lockerOperation?.compartmentID, "01")
        await harness.store.completeLockerOperation()
        XCTAssertFalse(harness.store.hasPendingLocker)
        XCTAssertEqual(harness.store.lastSaved?.status, "stored")
        XCTAssertEqual(harness.store.lockerOperation?.state, "completed")
        XCTAssertEqual(bodies.value.count, 1, "Confirmation must not open the door again")
    }

    func testLostResponsePersistsRequestAcrossRelaunchAndStatusRecoveryNeverPosts() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = item(status: "stored")
        let lockerStatus = status()
        let command = LockedValue<LockerOperationRequest?>(nil)
        let posts = LockedValue(0)
        harness.respond { request in
            if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(lockerStatus)) }
            if request.url!.path == "/api/locker-operations" {
                posts.modify { $0 += 1 }
                command.modify { $0 = try? JSONDecoder().decode(LockerOperationRequest.self, from: readBody(request)) }
                return .failure(URLError(.timedOut))
            }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [saved], total: 1)))
        }
        await harness.store.refreshLockers()
        await harness.store.beginRetrieval(for: saved)
        XCTAssertTrue(harness.store.hasPendingLocker)
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertNil(harness.store.lockerItem)
        XCTAssertNil(harness.store.lockerOperation)
        XCTAssertTrue(harness.store.lockerNeedsStaff)
        let restored = harness.relaunch()
        XCTAssertTrue(restored.hasPendingLocker)
        XCTAssertTrue(restored.lockerNeedsStaff)
        XCTAssertNil(restored.lockerItem)
        XCTAssertThrowsError(try restored.changeServer(to: "https://new.invalid"))
        let expected = response(for: try XCTUnwrap(command.value))
        harness.respond { request in
            if request.httpMethod == "POST" { posts.modify { $0 += 1 } }
            if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(lockerStatus)) }
            if request.url!.path.hasPrefix("/api/locker-operations/") { return .json(body: try JSONEncoder().encode(expected)) }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }
        await restored.refreshLockerOperation()
        XCTAssertEqual(restored.lockerOperation?.id, command.value?.requestID)
        XCTAssertTrue(restored.hasPendingLocker)
        await restored.completeLockerOperation()
        XCTAssertEqual(posts.value, 1, "A restored staff-held operation cannot auto-confirm or re-open")
    }

    func testBusyLockerRequestBlocksSessionResetAndConcurrentOpen() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = item(status: "stored")
        let lockerStatus = status()
        harness.respond { _ in .json(body: try JSONEncoder().encode(lockerStatus)) }
        // Supply the two endpoints used by refreshLockers.
        harness.respond { request in
            request.url!.path == "/api/lockers"
                ? .json(body: try JSONEncoder().encode(lockerStatus))
                : .json(body: try JSONEncoder().encode(ItemListResponse(items: [saved], total: 1)))
        }
        await harness.store.refreshLockers()
        let started = expectation(description: "Door request reached transport")
        let pending = LockedValue<StubURLProtocol?>(nil)
        harness.handle { transport in
            if transport.request.url!.path == "/api/locker-operations" {
                pending.modify { $0 = transport }; started.fulfill()
            } else if transport.request.url!.path == "/api/lockers" {
                transport.complete(.json(body: try! JSONEncoder().encode(lockerStatus)))
            } else {
                transport.complete(.json(body: try! JSONEncoder().encode(ItemListResponse(items: [], total: 0))))
            }
        }
        XCTAssertTrue(harness.store.beginVisitorTask(.find))
        let task = Task { await harness.store.beginRetrieval(for: saved) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(harness.store.isLockerBusy)
        XCTAssertFalse(harness.store.endVisitorSession())
        XCTAssertFalse(harness.store.beginVisitorTask(.report))
        await harness.store.beginRetrieval(for: saved)
        let transport = try XCTUnwrap(pending.value)
        let command = try JSONDecoder().decode(LockerOperationRequest.self, from: readBody(transport.request))
        transport.complete(.json(body: try JSONEncoder().encode(response(for: command))))
        await task.value
        XCTAssertFalse(harness.store.isLockerBusy)
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertTrue(harness.store.lockerNeedsStaff)
    }

    func testAvailabilityRefreshClearsCompletedHeldRequestAndRestoresRegistration() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let operation = try await beginDoorRetrieval(harness, door: LockerDoor(enabled: true, state: .open))
        XCTAssertTrue(harness.store.endVisitorSession())
        let restored = harness.relaunch()
        XCTAssertFalse(restored.beginVisitorTask(.report))
        let command = LockerOperationRequest(requestID: operation.id, itemID: operation.itemID, kind: operation.kind)
        let completed = response(for: command, state: "completed")
        let available = status()
        let paths = LockedValue<[String]>([])
        harness.respond { request in
            XCTAssertEqual(request.httpMethod, "GET", "Reconciliation must never open or confirm a compartment")
            paths.modify { $0.append(request.url!.path) }
            if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(available)) }
            if request.url!.path.hasPrefix("/api/locker-operations/") { return .json(body: try JSONEncoder().encode(completed)) }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }

        await restored.refreshLockers()

        XCTAssertEqual(paths.value.filter { $0.hasPrefix("/api/locker-operations/") }, ["/api/locker-operations/\(operation.id)"])
        XCTAssertFalse(restored.hasPendingLocker)
        XCTAssertFalse(restored.lockerNeedsStaff)
        XCTAssertFalse(harness.relaunch().hasPendingLocker, "The obsolete journal must be removed durably")
        XCTAssertNil(restored.lockerOperation, "Previous visitor details must not appear on the public screen")
        XCTAssertNil(restored.lockerItem)
        XCTAssertTrue(restored.beginVisitorTask(.report))
    }

    func testAvailabilityRefreshRetainsUnfinishedMissingOrUnreachableRequest() async throws {
        for mode in ["unfinished", "missing", "offline", "mismatched"] {
            let harness = StoreHarness()
            defer { harness.close() }
            let operation = try await beginDoorRetrieval(harness, door: LockerDoor(enabled: true, state: .closed))
            XCTAssertTrue(harness.store.endVisitorSession())
            let available = status() // An empty active list alone is never enough to clear a local request.
            let command = LockerOperationRequest(requestID: mode == "mismatched" ? UUID().uuidString.lowercased() : operation.id,
                                                 itemID: operation.itemID, kind: operation.kind)
            let reply = response(for: command, state: mode == "unfinished" ? "awaiting_confirmation" : "completed")
            harness.respond { request in
                XCTAssertEqual(request.httpMethod, "GET")
                if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(available)) }
                if request.url!.path.hasPrefix("/api/locker-operations/") {
                    if mode == "missing" { return .json(status: 404, body: Data("{\"error\":\"Not found\"}".utf8)) }
                    if mode == "offline" { return .failure(URLError(.notConnectedToInternet)) }
                    return .json(body: try JSONEncoder().encode(reply))
                }
                return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
            }

            await harness.store.refreshLockers()

            XCTAssertTrue(harness.store.hasPendingLocker, mode)
            XCTAssertTrue(harness.store.lockerNeedsStaff, mode)
            XCTAssertTrue(harness.relaunch().hasPendingLocker, mode)
            XCTAssertNil(harness.store.lockerOperation, mode)
            XCTAssertFalse(harness.store.beginVisitorTask(.report), mode)
        }
    }

    func testCompletedRequestReconciliationRejectsCancelledOrPreviousVisitResponse() async throws {
        for cancel in [false, true] {
            let harness = StoreHarness()
            defer { harness.close() }
            let operation = try await beginDoorRetrieval(harness, door: LockerDoor(enabled: true, state: .closed))
            XCTAssertTrue(harness.store.endVisitorSession())
            let available = status()
            let command = LockerOperationRequest(requestID: operation.id, itemID: operation.itemID, kind: operation.kind)
            let completed = response(for: command, state: "completed")
            let started = expectation(description: "Held request lookup started")
            let pending = LockedValue<StubURLProtocol?>(nil)
            harness.handle { transport in
                if transport.request.url!.path == "/api/lockers" {
                    transport.complete(.json(body: try! JSONEncoder().encode(available)))
                } else if transport.request.url!.path.hasPrefix("/api/locker-operations/") {
                    pending.modify { $0 = transport }; started.fulfill()
                } else {
                    transport.complete(.json(body: try! JSONEncoder().encode(ItemListResponse(items: [], total: 0))))
                }
            }
            let refresh = Task { await harness.store.refreshLockers() }
            await fulfillment(of: [started], timeout: 3)
            XCTAssertFalse(harness.store.isLockerBusy)
            if cancel { refresh.cancel() }
            else {
                XCTAssertTrue(harness.store.beginVisitorTask(.find))
                harness.store.recordVisitorActivity(at: Date().addingTimeInterval(-151))
                try XCTUnwrap(pending.value).complete(.json(body: JSONEncoder().encode(completed)))
            }
            await refresh.value
            XCTAssertTrue(harness.store.hasPendingLocker)
            XCTAssertTrue(harness.store.lockerNeedsStaff)
            if !cancel {
                harness.store.checkVisitorInactivity()
                XCTAssertEqual(harness.store.selectedTab, .home, "Background reconciliation must not renew visitor activity")
            }
        }
    }

    func testDefinitiveRejectionDoesNotLeaveAnUnrecoverablePendingRequest() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let lockerStatus = status()
        harness.respond { request in
            if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(lockerStatus)) }
            if request.httpMethod == "POST" { return .json(status: 409, body: Data("{\"error\":\"Item is no longer available\"}".utf8)) }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }
        await harness.store.refreshLockers()
        await harness.store.beginRetrieval(for: item(status: "stored"))
        XCTAssertFalse(harness.store.hasPendingLocker)
        XCTAssertEqual(harness.store.lockerError, "Item is no longer available")
        XCTAssertFalse(harness.relaunch().hasPendingLocker)
    }

    func testOldReportCannotAllocateAfterVisitorEnds() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let calls = LockedValue(0)
        harness.respond { _ in calls.modify { $0 += 1 }; return .failure(URLError(.timedOut)) }
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        XCTAssertTrue(harness.store.endVisitorSession())
        await harness.store.beginDeposit(for: item())
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(harness.store.hasPendingLocker)
    }

    func testJournalFailurePreventsAnyDoorRequest() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let lockerStatus = status()
        let posts = LockedValue(0)
        harness.respond { request in
            if request.httpMethod == "POST" { posts.modify { $0 += 1 } }
            if request.url!.path == "/api/lockers" {
                return .json(body: try JSONEncoder().encode(lockerStatus))
            }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }
        await harness.store.refreshLockers()
        try harness.blockLockerJournal()

        await harness.store.beginRetrieval(for: item(status: "stored"))

        XCTAssertEqual(posts.value, 0)
        XCTAssertFalse(harness.store.hasPendingLocker)
        XCTAssertFalse(harness.store.isLockerBusy)
        XCTAssertNotNil(harness.store.lockerError)
    }

    func testInventoryRefreshFailureClearsStaleLockerAvailability() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let lockerStatus = status()
        let saved = item(status: "stored")
        harness.respond { request in
            if request.url!.path == "/api/lockers" {
                return .json(body: try JSONEncoder().encode(lockerStatus))
            }
            return .json(body: try JSONEncoder().encode(ItemListResponse(items: [saved], total: 1)))
        }
        await harness.store.refreshLockers()
        XCTAssertEqual(harness.store.availableItems.count, 1)
        harness.respond { _ in .failure(URLError(.notConnectedToInternet)) }

        await harness.store.refresh()

        XCTAssertNil(harness.store.lockerStatus)
        XCTAssertTrue(harness.store.availableItems.isEmpty)
    }

    func testAssignedCompartmentSurvivesCanceledFollowupAndOlderRefresh() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = item()
        let door = LockerDoor(enabled: true, gpio: 12, pin: 32, state: .closed, level: 0)
        let free = status(first: LockerCompartment(id: "01", state: "free", door: door))
        let empty = ItemListResponse(items: [], total: 0)
        harness.respond { request in
            if request.url!.path == "/api/lockers" { return .json(body: try JSONEncoder().encode(free)) }
            if request.httpMethod == "POST" {
                return .json(body: try JSONEncoder().encode(SaveItemResponse(item: saved, duplicate: false)))
            }
            return .json(body: try JSONEncoder().encode(empty))
        }
        await harness.store.refreshLockers()
        XCTAssertTrue(harness.store.beginVisitorTask(.report))
        harness.store.setPhoto(Data([1]))
        await harness.store.savePhoto()
        let earlierStarted = expectation(description: "Older status request started")
        let followupStarted = expectation(description: "Post-deposit status request started")
        let earlier = LockedValue<StubURLProtocol?>(nil)
        let count = LockedValue(0)
        let buildResponse: (LockerOperationRequest) -> LockerOperationResponse = { [self] in response(for: $0) }
        harness.handle { transport in
            if transport.request.url!.path == "/api/lockers" {
                if count.modify({ $0 += 1; return $0 }) == 1 {
                    earlier.modify { $0 = transport }; earlierStarted.fulfill()
                } else { followupStarted.fulfill() }
            } else if transport.request.url!.path == "/api/locker-operations" {
                let command = try! JSONDecoder().decode(LockerOperationRequest.self, from: readBody(transport.request))
                transport.complete(.json(body: try! JSONEncoder().encode(buildResponse(command))))
            } else { transport.complete(.json(body: try! JSONEncoder().encode(empty))) }
        }
        let oldRefresh = Task { await harness.store.refreshLockers() }
        await fulfillment(of: [earlierStarted], timeout: 3)
        let deposit = Task { await harness.store.beginDeposit(for: saved) }
        await fulfillment(of: [followupStarted], timeout: 3)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.state, "reserved")
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.itemID, saved.id)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.door, door)
        XCTAssertTrue(harness.store.requiresDoorFeedback)
        XCTAssertEqual(harness.store.lockerStatus?.operations.first?.state, "awaiting_confirmation")
        deposit.cancel()
        await deposit.value
        try XCTUnwrap(earlier.value).complete(.json(body: JSONEncoder().encode(free)))
        await oldRefresh.value
        XCTAssertTrue(harness.store.endVisitorSession())
        XCTAssertEqual(harness.store.selectedTab, .home)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.filter { $0.state == "free" }.count, 3)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.state, "reserved")
    }

    func testFreshStatusPublishesBeforeCanceledAvailableItemList() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let saved = item(status: "stored")
        let occupied = status(first: LockerCompartment(id: "01", state: "occupied", itemID: saved.id))
        harness.respond { request in
            request.url!.path == "/api/lockers"
                ? .json(body: try JSONEncoder().encode(occupied))
                : .json(body: try JSONEncoder().encode(ItemListResponse(items: [saved], total: 1)))
        }
        await harness.store.refreshLockers()
        XCTAssertEqual(harness.store.storedItems.count, 1)
        let retrieving = status(first: LockerCompartment(id: "01", state: "retrieving", itemID: saved.id))
        let listStarted = expectation(description: "Secondary list request started")
        harness.handle { transport in
            if transport.request.url!.path == "/api/lockers" {
                transport.complete(.json(body: try! JSONEncoder().encode(retrieving)))
            } else { listStarted.fulfill() }
        }
        let refresh = Task { await harness.store.refreshLockers() }
        await fulfillment(of: [listStarted], timeout: 3)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.state, "retrieving")
        XCTAssertTrue(harness.store.storedItems.isEmpty)
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.state, "retrieving")
        XCTAssertTrue(harness.store.availableItems.isEmpty)
    }

    func testOldCompletedReplayCannotReleaseAnotherItemsCompartment() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let newOwner = "1ddf0bbc-a7de-4ad5-a4ad-e1e6f2ed7a2f"
        let occupied = status(first: LockerCompartment(id: "01", state: "occupied", itemID: newOwner))
        harness.respond { request in
            request.url!.path == "/api/lockers"
                ? .json(body: try JSONEncoder().encode(occupied))
                : .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }
        await harness.store.refreshLockers()
        let historical = LockerOperation(id: UUID().uuidString.lowercased(), kind: "retrieve", itemID: itemID,
                                         compartmentID: "01", state: "completed")
        let collected = FoundItem(id: itemID, createdAt: "", note: "", imageURL: "", status: "collected")
        let reply = LockerOperationResponse(operation: historical, item: collected)
        let followup = expectation(description: "Historical replay follow-up started")
        harness.handle { transport in
            if transport.request.httpMethod == "POST" {
                transport.complete(.json(body: try! JSONEncoder().encode(reply)))
            } else { followup.fulfill() }
        }
        let resolve = Task { await harness.store.resolveLockerOperation(historical, outcome: "collected") }
        await fulfillment(of: [followup], timeout: 3)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.state, "occupied")
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.itemID, newOwner)
        resolve.cancel()
        await resolve.value
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.itemID, newOwner)
    }

    func testCollectionResponseReleasesItsOwnCompartmentBeforeFollowup() async throws {
        let harness = StoreHarness()
        defer { harness.close() }
        let operation = LockerOperation(id: UUID().uuidString.lowercased(), kind: "retrieve", itemID: itemID,
                                        compartmentID: "01", state: "awaiting_confirmation")
        let retrieving = status(first: LockerCompartment(id: "01", state: "retrieving", itemID: itemID), operations: [operation])
        harness.respond { request in
            request.url!.path == "/api/lockers"
                ? .json(body: try JSONEncoder().encode(retrieving))
                : .json(body: try JSONEncoder().encode(ItemListResponse(items: [], total: 0)))
        }
        await harness.store.refreshLockers()
        let completed = LockerOperation(id: operation.id, kind: "retrieve", itemID: itemID,
                                        compartmentID: "01", state: "completed")
        let collected = FoundItem(id: itemID, createdAt: "", note: "", imageURL: "", status: "collected")
        let reply = LockerOperationResponse(operation: completed, item: collected)
        let followup = expectation(description: "Collection follow-up started")
        harness.handle { transport in
            if transport.request.httpMethod == "POST" {
                transport.complete(.json(body: try! JSONEncoder().encode(reply)))
            } else { followup.fulfill() }
        }
        let resolve = Task { await harness.store.resolveLockerOperation(operation, outcome: "collected") }
        await fulfillment(of: [followup], timeout: 3)
        XCTAssertEqual(harness.store.lockerStatus?.compartments.first?.state, "free")
        XCTAssertNil(harness.store.lockerStatus?.compartments.first?.itemID)
        XCTAssertTrue(harness.store.lockerStatus?.operations.isEmpty == true)
        resolve.cancel()
        await resolve.value
    }
}
