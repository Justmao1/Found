import Foundation

public struct Recognition: Codable, Hashable, Sendable {
    public let tags: [String]

    public init(tags: [String]) {
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case tags
    }
}

public struct FoundItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let createdAt: String
    public let note: String
    public let imageURL: String
    public let status: String
    public let recognition: Recognition?
    public let recognitionStatus: String

    public init(id: String, createdAt: String, note: String, imageURL: String,
                status: String = "recorded", recognition: Recognition? = nil,
                recognitionStatus: String = "disabled") {
        self.id = id
        self.createdAt = createdAt
        self.note = note
        self.imageURL = imageURL
        self.status = status
        self.recognition = recognition
        self.recognitionStatus = recognitionStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id, note, status, recognition
        case createdAt = "created_at"
        case imageURL = "image_url"
        case recognitionStatus = "recognition_status"
    }
}

public struct ItemListResponse: Codable, Sendable {
    public let items: [FoundItem]
    public let total: Int

    public init(items: [FoundItem], total: Int) {
        self.items = items
        self.total = total
    }

    private enum CodingKeys: String, CodingKey {
        case items, total
    }
}

public struct AIStatus: Codable, Sendable {
    public let configured: Bool

    public init(configured: Bool) {
        self.configured = configured
    }

    private enum CodingKeys: String, CodingKey {
        case configured
    }
}

public struct SaveItemRequest: Codable, Sendable {
    public let image: String
    public let mimeType: String
    public let requestID: String
    public let note: String

    public init(image: String, mimeType: String = "image/jpeg",
                requestID: String = UUID().uuidString.lowercased(), note: String) {
        self.image = image
        self.mimeType = mimeType
        self.requestID = requestID
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case image, note
        case mimeType = "mime_type"
        case requestID = "request_id"
    }
}

public struct SaveItemResponse: Codable, Sendable {
    public let item: FoundItem
    public let duplicate: Bool

    public init(item: FoundItem, duplicate: Bool) {
        self.item = item
        self.duplicate = duplicate
    }

    private enum CodingKeys: String, CodingKey {
        case item, duplicate
    }
}

public struct SearchMatch: Codable, Identifiable, Hashable, Sendable {
    public let item: FoundItem
    public let reason: String
    public var id: String { item.id }

    public init(item: FoundItem, reason: String) {
        self.item = item
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case item, reason
    }
}

public struct SearchResponse: Codable, Sendable {
    public let matches: [SearchMatch]
    public let searchedCount: Int
    public let pendingCount: Int

    public init(matches: [SearchMatch], searchedCount: Int, pendingCount: Int) {
        self.matches = matches
        self.searchedCount = searchedCount
        self.pendingCount = pendingCount
    }

    private enum CodingKeys: String, CodingKey {
        case matches
        case searchedCount = "searched_count"
        case pendingCount = "pending_count"
    }
}
