import Foundation

public struct LockerCompartment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let state: String
    public let itemID: String?

    public init(id: String, state: String, itemID: String? = nil) {
        self.id = id; self.state = state; self.itemID = itemID
    }
    enum CodingKeys: String, CodingKey {
        case id, state
        case itemID = "item_id"
    }
}

public struct LockerOperation: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let itemID: String
    public let compartmentID: String
    public let state: String
    public let error: String?

    public init(id: String, kind: String, itemID: String, compartmentID: String,
                state: String, error: String? = nil) {
        self.id = id; self.kind = kind; self.itemID = itemID
        self.compartmentID = compartmentID; self.state = state; self.error = error
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, state, error
        case itemID = "item_id"
        case compartmentID = "compartment_id"
    }
}

public struct LockerStatusResponse: Codable, Sendable {
    public let enabled: Bool
    public let driver: String
    public let compartments: [LockerCompartment]
    public let operations: [LockerOperation]

    public init(enabled: Bool, driver: String, compartments: [LockerCompartment], operations: [LockerOperation]) {
        self.enabled = enabled; self.driver = driver
        self.compartments = compartments; self.operations = operations
    }
}

public struct LockerOperationRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let itemID: String
    public let kind: String

    public init(requestID: String = UUID().uuidString.lowercased(), itemID: String, kind: String) {
        self.requestID = requestID; self.itemID = itemID; self.kind = kind
    }
    enum CodingKeys: String, CodingKey {
        case kind
        case requestID = "request_id"
        case itemID = "item_id"
    }
}

public struct LockerOperationResponse: Codable, Sendable {
    public let operation: LockerOperation
    public let item: FoundItem

    public init(operation: LockerOperation, item: FoundItem) {
        self.operation = operation; self.item = item
    }
}

public extension FoundItem {
    var isStored: Bool { status == "stored" && compartmentID != nil }
}
