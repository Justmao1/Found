import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LostFoundCore

final class LockerAPITests: XCTestCase, @unchecked Sendable {
    private let operationID = "bbccddaa-1234-4567-89ab-0123456789ab"

    func testPublicInventoryRequestsServerSideAvailabilityFiltering() async throws {
        let (client, transport, session) = makeClient(json: "{\"items\":[],\"total\":0}")
        defer { session.invalidateAndCancel() }
        _ = try await client.items(availableOnly: true)
        let captured = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(captured.request.url?.absoluteString, "https://station.local:8443/api/items?available=1")
        XCTAssertEqual(captured.request.httpMethod, "GET")
        XCTAssertNil(captured.body)
    }

    func testSnapshotDecodesFourCompartmentsAndRecoveryWithoutInventingAvailability() async throws {
        let json = """
        {"enabled":true,"driver":"gpio","compartments":[
          {"id":"01","state":"free","item_id":null},
          {"id":"02","state":"occupied","item_id":"\(Fixtures.identifier)"},
          {"id":"03","state":"reserved","item_id":"another"},
          {"id":"04","state":"recovery","item_id":"interrupted"}],
          "operations":[\(operation(state: "uncertain", error: "Ask staff to inspect the compartment."))]}
        """
        let (client, transport, session) = makeClient(json: json)
        defer { session.invalidateAndCancel() }
        let result = try await client.lockers()
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.driver, "gpio")
        XCTAssertEqual(result.compartments.map(\.id), ["01", "02", "03", "04"])
        XCTAssertNil(result.compartments[0].itemID)
        XCTAssertNil(result.compartments[0].door, "Legacy servers retain manual confirmation")
        XCTAssertNil(result.operations.first?.door)
        XCTAssertEqual(result.compartments[3].state, "recovery")
        XCTAssertEqual(result.operations.first?.state, "uncertain")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.request.url?.path, "/api/lockers")
        XCTAssertEqual(request.request.httpMethod, "GET")
        XCTAssertNil(request.body)
    }

    func testBeginPreservesOperationIdentityAndExactPayloadForSafeReplay() async throws {
        for status in [201, 200] {
            let (client, transport, session) = makeClient(status: status, json: response())
            defer { session.invalidateAndCancel() }
            let command = LockerOperationRequest(requestID: operationID, itemID: Fixtures.identifier, kind: "deposit")
            let result = try await client.beginLockerOperation(command)
            _ = try await client.beginLockerOperation(command)
            XCTAssertEqual(result.operation.id, operationID)
            XCTAssertEqual(result.operation.compartmentID, "01")
            XCTAssertEqual(result.item.status, "deposit_pending")
            XCTAssertEqual(result.item.compartmentID, "01")
            let captured = try XCTUnwrap(transport.requests.first)
            let body = try XCTUnwrap(captured.body)
            XCTAssertEqual(captured.request.url?.path, "/api/locker-operations")
            XCTAssertEqual(captured.request.httpMethod, "POST")
            XCTAssertEqual(captured.request.value(forHTTPHeaderField: "X-Requested-With"), "lost-found-box")
            XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
            XCTAssertEqual(try JSONDecoder().decode(LockerOperationRequest.self, from: body), command)
            XCTAssertEqual(transport.requests.last?.body, body)
        }
    }

    func testNewCommandsHaveIndependentCanonicalIdentities() {
        let first = LockerOperationRequest(itemID: Fixtures.identifier, kind: "deposit")
        let second = LockerOperationRequest(itemID: Fixtures.identifier, kind: "deposit")
        XCTAssertNotNil(UUID(uuidString: first.requestID))
        XCTAssertEqual(first.requestID, first.requestID.lowercased())
        XCTAssertNotEqual(first.requestID, second.requestID)
    }

    func testDoorFeedbackDecodesOnBothCompartmentAndOperation() throws {
        let door = """
        {"enabled":true,"gpio":12,"pin":32,"state":"closed","level":0,
         "updated_at":1792656000.25,"error":null}
        """
        let compartment = try JSONDecoder().decode(LockerCompartment.self, from: Data("""
        {"id":"01","state":"reserved","door":\(door)}
        """.utf8))
        let operationJSON = operation().dropLast() + ",\"door\":\(door)}"
        let operation = try JSONDecoder().decode(LockerOperation.self, from: Data(operationJSON.utf8))
        XCTAssertEqual(compartment.door, operation.door)
        XCTAssertEqual(operation.door?.state, .closed)
        XCTAssertEqual(operation.door?.gpio, 12)
        XCTAssertEqual(operation.door?.pin, 32)
        XCTAssertEqual(operation.door?.level, 0)
        XCTAssertEqual(operation.door?.updatedAt, 1792656000.25)
        let roundTrip = try JSONDecoder().decode(LockerOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertEqual(roundTrip, operation)
    }

    func testUnconfiguredAndUnknownDoorStatesRemainDistinct() throws {
        let decoder = JSONDecoder()
        let unconfigured = try decoder.decode(LockerDoor.self, from: Data("""
        {"enabled":false,"state":"not_configured","gpio":null,"pin":null,"level":null,"updated_at":null}
        """.utf8))
        XCTAssertFalse(unconfigured.enabled)
        XCTAssertEqual(unconfigured.state, .notConfigured)
        let futureState = try decoder.decode(LockerDoor.self, from: Data("""
        {"enabled":true,"state":"future_sensor_state"}
        """.utf8))
        XCTAssertTrue(futureState.enabled)
        XCTAssertEqual(futureState.state, .unknown)
        XCTAssertNil(futureState.level)
    }

    func testRecoveryLookupIsReadOnlyAndCanonicalizesTheOperationID() async throws {
        let (client, transport, session) = makeClient(json: response())
        defer { session.invalidateAndCancel() }
        _ = try await client.lockerOperation(id: operationID.uppercased())
        let captured = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(captured.request.url?.path, "/api/locker-operations/\(operationID)")
        XCTAssertEqual(captured.request.httpMethod, "GET")
        XCTAssertNil(captured.body)
        XCTAssertEqual(captured.request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testCompletionAndStaffResolutionUseSeparateExplicitCommands() async throws {
        let (client, transport, session) = makeClient(json: response(state: "completed", itemStatus: "stored"))
        defer { session.invalidateAndCancel() }
        let completed = try await client.completeLockerOperation(id: operationID.uppercased())
        XCTAssertTrue(completed.item.isStored)
        let completion = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(completion.request.url?.path, "/api/locker-operations/\(operationID)/complete")
        XCTAssertEqual(completion.request.httpMethod, "POST")
        XCTAssertEqual(completion.body, Data("{}".utf8))
        _ = try await client.resolveLockerOperation(id: operationID.uppercased(), outcome: "stored")
        let resolution = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(resolution.request.url?.path, "/api/locker-operations/\(operationID)/resolve")
        XCTAssertEqual(resolution.request.httpMethod, "POST")
        XCTAssertEqual(resolution.body, Data("{\"outcome\":\"stored\"}".utf8))
    }

    func testInvalidOperationIDsNeverReachTheNetwork() async throws {
        let (client, transport, session) = makeClient(json: response())
        defer { session.invalidateAndCancel() }
        for id in ["../items", "", operationID + "/complete"] {
            do {
                _ = try await client.lockerOperation(id: id)
                XCTFail("An invalid ID must not construct a request")
            } catch APIError.server(let status, _) {
                XCTAssertEqual(status, 404)
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUncertainActuationRemainsARecoveryResponse() async throws {
        let (client, _, session) = makeClient(json: response(state: "uncertain", itemStatus: "recovery",
                                                          error: "Opening could not be confirmed."))
        defer { session.invalidateAndCancel() }
        let result = try await client.beginLockerOperation(
            LockerOperationRequest(requestID: operationID, itemID: Fixtures.identifier, kind: "deposit"))
        XCTAssertEqual(result.operation.state, "uncertain")
        XCTAssertEqual(result.operation.error, "Opening could not be confirmed.")
        XCTAssertEqual(result.item.compartmentID, "01")
        XCTAssertFalse(result.item.isStored)
    }

    func testCapacityAndCooldownErrorsArePreservedWithoutRetryingTheCommand() async throws {
        for status in [409, 429, 503] {
            let (client, transport, session) = makeClient(status: status, json: "{\"error\":\"Ask staff for assistance.\"}")
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.beginLockerOperation(
                    LockerOperationRequest(itemID: Fixtures.identifier, kind: "deposit"))
                XCTFail("The command must not succeed")
            } catch APIError.server(let code, let message) {
                XCTAssertEqual(code, status)
                XCTAssertEqual(message, "Ask staff for assistance.")
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testLostResponseDoesNotAutomaticallyIssueAnotherOpeningCommand() async throws {
        let (client, transport, session) = makeClient(json: "{}", failure: .timedOut)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.beginLockerOperation(
                LockerOperationRequest(itemID: Fixtures.identifier, kind: "retrieve"))
            XCTFail("A timeout must remain unresolved")
        } catch APIError.network {}
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testOnlyStoredItemsWithACompartmentAreEligibleForRetrieval() throws {
        let legacy = try JSONDecoder().decode(FoundItem.self, from: Fixtures.data(Fixtures.item))
        XCTAssertNil(legacy.compartmentID)
        XCTAssertFalse(legacy.isStored)
        for state in ["recorded", "deposit_pending", "retrieval_pending", "collected", "recovery"] {
            let item = FoundItem(id: Fixtures.identifier, createdAt: "", note: "", imageURL: "",
                                 status: state, compartmentID: "01")
            XCTAssertFalse(item.isStored, state)
        }
        let missingSlot = FoundItem(id: Fixtures.identifier, createdAt: "", note: "", imageURL: "", status: "stored")
        XCTAssertFalse(missingSlot.isStored)
    }

    private func operation(state: String = "awaiting_confirmation", error: String? = nil) -> String {
        let errorJSON = error.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(operationID)","kind":"deposit","item_id":"\(Fixtures.identifier)",
         "compartment_id":"01","state":"\(state)","error":\(errorJSON)}
        """
    }

    private func response(state: String = "awaiting_confirmation", itemStatus: String = "deposit_pending",
                          error: String? = nil) -> String {
        let item = Fixtures.item.replacingOccurrences(of: "\"status\":\"recorded\"",
            with: "\"status\":\"\(itemStatus)\",\"compartment_id\":\"01\"")
        return "{\"operation\":\(operation(state: state, error: error)),\"item\":\(item)}"
    }

    private func makeClient(status: Int = 200, json: String, failure: URLError.Code? = nil)
        -> (APIClient, LockerTestTransport, URLSession) {
        let transport = LockerTestTransport(status: status, json: json, failure: failure)
        let key = UUID().uuidString
        LockerTestProtocol.registry.set(transport, for: key)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LockerTestProtocol.self]
        config.httpAdditionalHeaders = ["X-Locker-Test": key]
        let session = URLSession(configuration: config)
        return (APIClient(baseURL: URL(string: "https://station.local:8443")!, session: session), transport, session)
    }
}

private struct LockerCapturedRequest: Sendable {
    let request: URLRequest
    let body: Data?
}

private final class LockerTestTransport: @unchecked Sendable {
    let status: Int
    let json: String
    let failure: URLError.Code?
    private let lock = NSLock()
    private var captured: [LockerCapturedRequest] = []
    var requests: [LockerCapturedRequest] { lock.withLock { captured } }

    init(status: Int, json: String, failure: URLError.Code?) {
        self.status = status; self.json = json; self.failure = failure
    }

    func capture(_ request: URLRequest) {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        let value = LockerCapturedRequest(request: request, body: body)
        lock.withLock { captured.append(value) }
    }
}

private final class LockerTransportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [String: LockerTestTransport] = [:]
    func set(_ transport: LockerTestTransport, for key: String) { lock.withLock { transports[key] = transport } }
    func get(_ key: String) -> LockerTestTransport? { lock.withLock { transports[key] } }
}

private final class LockerTestProtocol: URLProtocol, @unchecked Sendable {
    static let registry = LockerTransportRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Locker-Test"),
              let transport = Self.registry.get(key), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        transport.capture(request)
        if let failure = transport.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: transport.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(transport.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
