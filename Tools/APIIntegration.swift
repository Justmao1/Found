import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct IntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct APIIntegration {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw IntegrationFailure(message: message) }
    }

    private static func expectServerError(
        _ expected: Int, operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch APIError.server(let status, let message) {
            try require(status == expected, "Expected HTTP \(expected), received \(status)")
            try require(!message.isEmpty, "Server error message was empty")
            return
        }
        throw IntegrationFailure(message: "Expected HTTP \(expected), but the operation succeeded")
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw IntegrationFailure(message: "Usage: api-integration <loopback-origin> <fixture.png>")
        }
        let baseURL = try ServerAddress.parse(CommandLine.arguments[1])
        try require(baseURL.host == "127.0.0.1" && baseURL.scheme == "http",
                    "Integration harness only connects to its local test server")
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: baseURL, session: session)

        try await client.health()
        print("PASS health: real GET /api/health")

        let status = try await client.aiStatus()
        try require(!status.configured, "AI must be disabled in the isolated test server")
        let empty = try await client.items()
        try require(empty.items.isEmpty && empty.total == 0, "Temporary inventory must start empty")
        print("PASS isolation: AI disabled and inventory empty")

        let request = SaveItemRequest(image: fixture.base64EncodedString(), mimeType: "image/png",
                                      note: "红色钥匙扣 🔑")
        let saved = try await client.save(request)
        try require(!saved.duplicate, "Initial upload unexpectedly marked duplicate")
        try require(saved.item.note == request.note, "Unicode note did not round trip")
        try require(saved.item.recognition == nil && saved.item.recognitionStatus == "disabled",
                    "Upload must be saved with recognition disabled")
        try require(saved.item.createdAt.hasSuffix("Z"), "Timestamp was not UTC")
        print("PASS upload: generated PNG and Unicode note saved through APIClient")

        let retry = try await client.save(request)
        try require(retry.duplicate && retry.item.id == saved.item.id,
                    "Identical retry did not return the original item")
        print("PASS idempotency: identical request returns duplicate=true and same item ID")

        let conflicting = SaveItemRequest(image: request.image, mimeType: request.mimeType,
                                          requestID: request.requestID, note: "different note")
        try await expectServerError(409) { _ = try await client.save(conflicting) }
        print("PASS conflict: changed payload with same request ID returns HTTP 409")

        guard let imageURL = client.imageURL(for: saved.item) else {
            throw IntegrationFailure(message: "APIClient rejected the server image URL")
        }
        let (image, response) = try await session.data(from: imageURL)
        try require((response as? HTTPURLResponse)?.statusCode == 200, "Image fetch failed")
        try require(response.mimeType == "image/png", "Image response has wrong MIME type")
        try require(image == fixture, "Original PNG bytes were not preserved")
        print("PASS image: original PNG bytes and image/png MIME type round trip")

        try await expectServerError(503) { _ = try await client.recognize(id: saved.item.id) }
        print("PASS recognition: disabled AI returns HTTP 503 without losing the photo")

        // Valid half-second WAV checks the native contract without cloud use.
        var wav = Data("RIFF".utf8)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        appendLE(UInt32(16_036)); wav.append(Data("WAVEfmt ".utf8))
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1))
        appendLE(UInt32(16_000)); appendLE(UInt32(32_000))
        appendLE(UInt16(2)); appendLE(UInt16(16)); wav.append(Data("data".utf8))
        appendLE(UInt32(16_000)); wav.append(Data(repeating: 0, count: 16_000))
        try await expectServerError(503) { _ = try await client.transcribe(audio: wav) }
        try await expectServerError(400) { _ = try await client.transcribe(audio: Data("not audio".utf8)) }
        print("PASS transcription: real WAV request reaches disabled provider; invalid audio rejected")

        let search = try await client.search(query: "红色的钥匙扣")
        try require(search.matches.isEmpty && search.searchedCount == 0 && search.pendingCount == 1,
                    "Untagged inventory search counts were incorrect")
        print("PASS search: no tagged matches, searched_count=0, pending_count=1")

        try await expectServerError(400) {
            _ = try await client.search(query: String(repeating: "x", count: 501))
        }
        print("PASS query limit: 501-character search returns HTTP 400")

        let final = try await client.items()
        try require(final.total == 1 && final.items.count == 1 && final.items.first?.id == saved.item.id,
                    "Retry/error paths unexpectedly changed inventory")
        print("PASS final inventory: exactly one saved item survives all error paths")
        print("RESULT: 12 real HTTP integration checks passed")
    }
}
