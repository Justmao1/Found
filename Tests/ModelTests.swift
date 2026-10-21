import Foundation
import XCTest
@testable import LostFoundCore

enum Fixtures {
    static let identifier = "aabbccdd-1234-4567-89ab-0123456789ab"
    static let item = """
    {"id":"\(identifier)","created_at":"2026-10-20T01:23:45.123Z","note":"红色钥匙扣",
     "image_url":"/images/\(identifier)","status":"recorded",
     "recognition":{"tags":["keys","red"],"model":"qwen3-vl-plus","version":3},
     "recognition_status":"complete"}
    """

    static func data(_ json: String) -> Data { Data(json.utf8) }
    static func foundItem(imageURL: String? = nil) -> FoundItem {
        FoundItem(id: identifier, createdAt: "2026-10-20T01:23:45.123Z", note: "",
                  imageURL: imageURL ?? "/images/\(identifier)")
    }
}

final class ModelTests: XCTestCase {
    func testDecodesActualServerItemAndFractionalTimestamp() throws {
        let item = try JSONDecoder().decode(FoundItem.self, from: Fixtures.data(Fixtures.item))
        XCTAssertEqual(item.id, Fixtures.identifier)
        XCTAssertEqual(item.createdAt, "2026-10-20T01:23:45.123Z")
        XCTAssertEqual(item.note, "红色钥匙扣")
        XCTAssertEqual(item.recognition?.tags, ["keys", "red"])
        XCTAssertEqual(item.recognitionStatus, "complete")
    }

    func testNullRecognitionAndUnknownFutureStatusRemainDecodable() throws {
        let item = Fixtures.foundItem()
        let data = try JSONEncoder().encode(item)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["recognition"] = NSNull()
        json["recognition_status"] = "future-state"
        let decoded = try JSONDecoder().decode(FoundItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.recognition)
        XCTAssertEqual(decoded.recognitionStatus, "future-state")
    }

    func testRequiredFieldTypeMismatchFailsRatherThanSilentlyFabricatingData() {
        XCTAssertThrowsError(try JSONDecoder().decode(ItemListResponse.self,
            from: Fixtures.data("{\"items\":[],\"total\":\"wrong\"}")))
        XCTAssertThrowsError(try JSONDecoder().decode(FoundItem.self,
            from: Fixtures.data("{\"id\":\"missing-fields\"}")))
    }

    func testSearchCountsAndOrderedMatchesDecode() throws {
        let json = """
        {"matches":[{"item":\(Fixtures.item),"reason":"The red keyring matches."}],
         "searched_count":101,"pending_count":3}
        """
        let result = try JSONDecoder().decode(SearchResponse.self, from: Fixtures.data(json))
        XCTAssertEqual(result.searchedCount, 101)
        XCTAssertEqual(result.pendingCount, 3)
        XCTAssertEqual(result.matches.first?.id, Fixtures.identifier)
        XCTAssertEqual(result.matches.first?.reason, "The red keyring matches.")
    }

    func testSaveRequestUsesSnakeCaseAndStableGeneratedUUID() throws {
        let request = SaveItemRequest(image: "aGVsbG8=", note: "  note unchanged  ")
        XCTAssertNotNil(UUID(uuidString: request.requestID))
        XCTAssertEqual(request.requestID, request.requestID.lowercased())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String])
        XCTAssertEqual(Set(json.keys), ["image", "mime_type", "request_id", "note"])
        XCTAssertEqual(json["mime_type"], "image/jpeg")
        XCTAssertEqual(json["request_id"], request.requestID)
        XCTAssertEqual(json["note"], "  note unchanged  ")
    }
}
