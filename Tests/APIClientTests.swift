import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LostFoundCore

final class APIClientTests: XCTestCase, @unchecked Sendable {
    func testTranscriptionSendsWAVToStationWithoutCloudCredentials() async throws {
        let (client, transport, session) = makeClient(.http(200, "{\"text\":\"  蓝色 backpack 🎒  \"}"))
        defer { session.invalidateAndCancel() }
        let audio = Data([82, 73, 70, 70, 0, 1, 2, 3])
        let text = try await client.transcribe(audio: audio)
        XCTAssertEqual(text, "蓝色 backpack 🎒")
        let captured = try XCTUnwrap(transport.lastRequest)
        let body = try XCTUnwrap(captured.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(captured.request.url?.absoluteString, "https://school.local:8443/api/transcribe")
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.timeoutInterval, 45)
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "X-Requested-With"), "lost-found-box")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertNil(captured.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(payload, ["audio": audio.base64EncodedString(), "mime_type": "audio/wav"])
    }

    func testTranscriptionRejectsEmptyOrOversizedDescription() async throws {
        for response in ["{\"text\":\" \\n \"}", "{\"text\":\"\(String(repeating: "蓝", count: 501))\"}"] {
            let (client, _, session) = makeClient(.http(200, response))
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.transcribe(audio: Data([1]))
                XCTFail("Unusable transcription should fail")
            } catch APIError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testItemsUsesGETOriginAndTwentySecondTimeout() async throws {
        let (client, transport, session) = makeClient(.http(200, "{\"items\":[\(Fixtures.item)],\"total\":102}"))
        defer { session.invalidateAndCancel() }
        let result = try await client.items()
        XCTAssertEqual(result.total, 102)
        XCTAssertEqual(result.items.count, 1)
        let captured = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(captured.request.url?.absoluteString, "https://school.local:8443/api/items")
        XCTAssertEqual(captured.request.httpMethod, "GET")
        XCTAssertEqual(captured.request.timeoutInterval, 20)
        XCTAssertEqual(captured.request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(captured.body)
    }

    func testAIStatusIgnoresAdditionalServerMetadata() async throws {
        let (client, _, session) = makeClient(.http(200, "{\"configured\":true,\"model\":\"qwen3-vl-plus\"}"))
        defer { session.invalidateAndCancel() }
        let status = try await client.aiStatus()
        XCTAssertTrue(status.configured)
    }

    func testHealthRequiresAnAffirmativeJSONResponse() async throws {
        let (client, _, session) = makeClient(.http(200, "{\"ok\":true}"))
        defer { session.invalidateAndCancel() }
        try await client.health()
        let (unhealthy, _, secondSession) = makeClient(.http(200, "{\"ok\":false}"))
        defer { secondSession.invalidateAndCancel() }
        do {
            try await unhealthy.health()
            XCTFail("False health response must not succeed")
        } catch APIError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSaveSetsFixedLengthJSONHeadersAndPreservesPayloadForRetry() async throws {
        let (client, transport, session) = makeClient(.http(201, "{\"item\":\(Fixtures.item),\"duplicate\":false}"))
        defer { session.invalidateAndCancel() }
        let payload = SaveItemRequest(image: "aGVsbG8=", requestID: Fixtures.identifier, note: "钥匙 🔑")
        let result = try await client.save(payload)
        XCTAssertFalse(result.duplicate)
        let first = try XCTUnwrap(transport.lastRequest)
        let body = try XCTUnwrap(first.body)
        XCTAssertEqual(first.request.httpMethod, "POST")
        XCTAssertEqual(first.request.url?.path, "/api/items")
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "X-Requested-With"), "lost-found-box")
        XCTAssertEqual(first.request.value(forHTTPHeaderField: "Content-Length"), String(body.count))
        XCTAssertNil(first.request.value(forHTTPHeaderField: "Transfer-Encoding"))
        XCTAssertNil(first.request.value(forHTTPHeaderField: "Origin"))
        let decoded = try JSONDecoder().decode(SaveItemRequest.self, from: body)
        XCTAssertEqual(decoded.note, payload.note)
        XCTAssertEqual(decoded.requestID, payload.requestID)
        _ = try await client.save(payload)
        XCTAssertEqual(transport.lastRequest?.body, body)
    }

    func testDuplicateSaveIsSuccess() async throws {
        let (client, _, session) = makeClient(.http(200, "{\"item\":\(Fixtures.item),\"duplicate\":true}"))
        defer { session.invalidateAndCancel() }
        let result = try await client.save(SaveItemRequest(image: "aGVsbG8=", note: ""))
        XCTAssertTrue(result.duplicate)
    }

    func testRecognitionUsesCanonicalUUIDEmptyObjectAndLongTimeout() async throws {
        let (client, transport, session) = makeClient(.http(200, "{\"item\":\(Fixtures.item)}"))
        defer { session.invalidateAndCancel() }
        let result = try await client.recognize(id: Fixtures.identifier.uppercased())
        XCTAssertEqual(result.id, Fixtures.identifier)
        let captured = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(captured.request.url?.path, "/api/items/\(Fixtures.identifier)/recognize")
        XCTAssertEqual(captured.request.timeoutInterval, 45)
        XCTAssertEqual(captured.body, Data("{}".utf8))
    }

    func testSearchPreservesUnicodeQueryAndCountsWithLongTimeout() async throws {
        let (client, transport, session) = makeClient(.http(200, "{\"matches\":[],\"searched_count\":12,\"pending_count\":4}"))
        defer { session.invalidateAndCancel() }
        let result = try await client.search(query: "红色的钥匙扣")
        XCTAssertEqual(result.searchedCount, 12)
        XCTAssertEqual(result.pendingCount, 4)
        let captured = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(captured.request.url?.path, "/api/search")
        XCTAssertEqual(captured.request.timeoutInterval, 45)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.body)) as? [String: String])
        XCTAssertEqual(json, ["query": "红色的钥匙扣"])
    }

    func testServerErrorMessageAndStatusArePreserved() async throws {
        let (client, _, session) = makeClient(.http(409, "{\"error\":\"This request ID was used for other content.\"}"))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.save(SaveItemRequest(image: "", note: ""))
            XCTFail("Conflict must throw")
        } catch APIError.server(let code, let message) {
            XCTAssertEqual(code, 409)
            XCTAssertEqual(message, "This request ID was used for other content.")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNonJSONErrorFallsBackToHTTPStatus() async throws {
        let (client, _, session) = makeClient(.http(503, "<html>Unavailable</html>"))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.items()
            XCTFail("Server failure must throw")
        } catch APIError.server(let code, let message) {
            XCTAssertEqual(code, 503)
            XCTAssertTrue(message.contains("503"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMalformedSuccessAndNonHTTPResponseAreRejected() async throws {
        for response in [MockResponse.http(200, "<html>Wrong server</html>"), .nonHTTP] {
            let (client, _, session) = makeClient(response)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.items()
                XCTFail("Invalid response must throw")
            } catch APIError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTransportErrorsAreReadableAndCancellationRemainsCancellation() async throws {
        let (client, _, session) = makeClient(.failure(.timedOut))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.items()
            XCTFail("Timeout must throw")
        } catch APIError.network(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch { XCTFail("Unexpected error: \(error)") }
        let (cancelled, _, secondSession) = makeClient(.failure(.cancelled))
        defer { secondSession.invalidateAndCancel() }
        do {
            _ = try await cancelled.items()
            XCTFail("Cancellation must throw")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testImageURLsMustStayAtTheConfiguredOrigin() throws {
        let client = APIClient(baseURL: try ServerAddress.parse("https://school.local:8443"))
        XCTAssertEqual(client.imageURL(for: Fixtures.foundItem())?.absoluteString,
                       "https://school.local:8443/images/\(Fixtures.identifier)")
        XCTAssertNotNil(client.imageURL(for: Fixtures.foundItem(imageURL: "https://school.local:8443/images/a")))
        for path in ["https://evil.test/photo", "//evil.test/photo", "http://school.local:8443/images/a",
                     "https://school.local:443/images/a", "https://user@school.local:8443/images/a",
                     "file:///tmp/photo", "data:image/png;base64,abc", ""] {
            XCTAssertNil(client.imageURL(for: Fixtures.foundItem(imageURL: path)), path)
        }
        let standard = APIClient(baseURL: try ServerAddress.parse("https://school.local"))
        XCTAssertNotNil(standard.imageURL(for: Fixtures.foundItem(imageURL: "https://school.local:443/images/a")))
    }

    private func makeClient(_ response: MockResponse) -> (APIClient, MockTransport, URLSession) {
        let transport = MockTransport(response: response)
        let identifier = UUID().uuidString
        MockURLProtocol.registry.set(transport, for: identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Transport": identifier]
        let session = URLSession(configuration: configuration)
        return (APIClient(baseURL: URL(string: "https://school.local:8443")!, session: session), transport, session)
    }
}

private enum MockResponse: Sendable {
    case http(Int, String)
    case failure(URLError.Code)
    case nonHTTP
}

private struct CapturedRequest: Sendable {
    let request: URLRequest
    let body: Data?
}

private final class MockTransport: @unchecked Sendable {
    let response: MockResponse
    private let lock = NSLock()
    private var captured: CapturedRequest?
    var lastRequest: CapturedRequest? { lock.withLock { captured } }

    init(response: MockResponse) { self.response = response }

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
        let value = CapturedRequest(request: request, body: body)
        lock.withLock { captured = value }
    }
}

private final class TransportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [String: MockTransport] = [:]
    func set(_ transport: MockTransport, for id: String) { lock.withLock { transports[id] = transport } }
    func get(_ id: String) -> MockTransport? { lock.withLock { transports[id] } }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = TransportRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let identifier = request.value(forHTTPHeaderField: "X-Test-Transport"),
              let transport = Self.registry.get(identifier), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        transport.capture(request)
        switch transport.response {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let json):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .nonHTTP:
            client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: nil, expectedContentLength: 0,
                                                             textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
