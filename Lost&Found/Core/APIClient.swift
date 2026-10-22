import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIError: LocalizedError, Sendable {
    case invalidServerAddress(String)
    case invalidResponse
    case server(statusCode: Int, message: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerAddress(let message), .server(_, let message), .network(let message):
            return message
        case .invalidResponse:
            return "The server returned an unexpected response. Check the server address and try again."
        }
    }
}

public struct APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func items(availableOnly: Bool = false) async throws -> ItemListResponse {
        try await get("api/items", queryItems: availableOnly ? [URLQueryItem(name: "available", value: "1")] : [])
    }

    public func aiStatus() async throws -> AIStatus {
        try await get("api/ai/status")
    }

    public func lockers() async throws -> LockerStatusResponse {
        try await get("api/lockers")
    }

    public func beginLockerOperation(_ request: LockerOperationRequest) async throws -> LockerOperationResponse {
        try await post("api/locker-operations", payload: request)
    }

    public func lockerOperation(id: String) async throws -> LockerOperationResponse {
        try await get(lockerPath(id))
    }

    public func completeLockerOperation(id: String) async throws -> LockerOperationResponse {
        try await post(lockerPath(id) + "/complete", payload: EmptyRequest())
    }

    public func resolveLockerOperation(id: String, outcome: String) async throws -> LockerOperationResponse {
        try await post(lockerPath(id) + "/resolve", payload: LockerResolution(outcome: outcome))
    }

    private func lockerPath(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else {
            throw APIError.server(statusCode: 404, message: "Locker operation not found")
        }
        return "api/locker-operations/" + uuid.uuidString.lowercased()
    }

    public func health() async throws {
        let response: HealthResponse = try await get("api/health")
        guard response.ok else { throw APIError.invalidResponse }
    }

    public func save(_ payload: SaveItemRequest) async throws -> SaveItemResponse {
        try await post("api/items", payload: payload)
    }

    public func recognize(id: String) async throws -> FoundItem {
        guard let identifier = UUID(uuidString: id) else {
            throw APIError.server(statusCode: 404, message: "Item not found")
        }
        let response: ItemResponse = try await post(
            "api/items/\(identifier.uuidString.lowercased())/recognize",
            payload: EmptyRequest(), timeout: 45
        )
        return response.item
    }

    public func search(query: String) async throws -> SearchResponse {
        try await post("api/search", payload: SearchRequest(query: query), timeout: 45)
    }

    public func transcribe(audio: Data) async throws -> String {
        let response: TranscriptionResponse = try await post(
            "api/transcribe", payload: TranscriptionRequest(audio: audio.base64EncodedString()), timeout: 45
        )
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 500 else { throw APIError.invalidResponse }
        return text
    }

    public func imageURL(for item: FoundItem) -> URL? {
        guard !item.imageURL.isEmpty,
              let url = URL(string: item.imageURL, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              scheme == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              effectivePort(url) == effectivePort(baseURL),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private func get<Response: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Response {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        return try await execute(request)
    }

    private func post<Payload: Encodable, Response: Decodable>(
        _ path: String, payload: Payload, timeout: TimeInterval = 20
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("lost-found-box", forHTTPHeaderField: "X-Requested-With")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        return try await execute(request)
    }

    private func execute<Response: Decodable>(_ original: URLRequest) async throws -> Response {
        var request = original
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let message = error?.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.server(
                statusCode: http.statusCode,
                message: message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Request failed (\(http.statusCode)). \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))."
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}

private struct HealthResponse: Decodable {
    let ok: Bool
    enum CodingKeys: String, CodingKey { case ok }
}

private struct ItemResponse: Decodable {
    let item: FoundItem
    enum CodingKeys: String, CodingKey { case item }
}

private struct ErrorResponse: Decodable {
    let error: String
    enum CodingKeys: String, CodingKey { case error }
}

private struct SearchRequest: Encodable {
    let query: String
    enum CodingKeys: String, CodingKey { case query }
}

private struct EmptyRequest: Encodable {}

private struct LockerResolution: Encodable { let outcome: String }

private struct TranscriptionRequest: Encodable {
    let audio: String
    let mime_type = "audio/wav"
}

private struct TranscriptionResponse: Decodable {
    let text: String
}
