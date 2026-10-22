import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct LockerIntegrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct LockerIntegration {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw LockerIntegrationFailure(message: message) }
    }

    private static func expectConflict(_ action: () async throws -> Void) async throws {
        do { try await action() }
        catch APIError.server(let code, let message) {
            try require(code == 409 && !message.isEmpty, "Expected an explicit HTTP 409 conflict, received \(code)")
            return
        }
        throw LockerIntegrationFailure(message: "An invalid operation unexpectedly succeeded")
    }

    private static func pulseCount(_ audit: URL) throws -> Int {
        try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").count
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw LockerIntegrationFailure(message: "Usage: locker-integration <loopback-origin> <items.json> <pulse-audit>")
        }
        let origin = try ServerAddress.parse(CommandLine.arguments[1])
        try require(origin.host == "127.0.0.1" && origin.scheme == "http", "Only the local fixture server is allowed")
        let ids = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        try require(ids.count == 7, "Expected six recognized fixtures and one unrecognized fixture")
        let audit = URL(fileURLWithPath: CommandLine.arguments[3])
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: origin, session: session)

        try await client.health()
        let ai = try await client.aiStatus()
        let initial = try await client.lockers()
        try require(!ai.configured && initial.enabled && initial.driver == "simulated", "Expected AI-disabled simulated station")
        try require(initial.compartments.map(\.id) == ["01", "02", "03", "04"], "Wrong compartment IDs")
        try require(initial.compartments.allSatisfy { $0.state == "free" && $0.itemID == nil }, "Slots must start empty")
        let initialAvailable = try await client.items(availableOnly: true)
        let initialSearch = try await client.search(query: "蓝色钥匙扣")
        try require(initialAvailable.total == 0 && initialSearch.searchedCount == 0, "Unstored legacy items leaked into public inventory")
        print("PASS isolation: four free compartments; recorded items excluded from browsing/search")

        try await expectConflict {
            _ = try await client.beginLockerOperation(LockerOperationRequest(itemID: ids[6], kind: "deposit"))
        }
        let unrecognizedPulses = try pulseCount(audit)
        try require(unrecognizedPulses == 0, "An unrecognized item must not open a compartment")
        print("PASS recognition gate: unrecognized item cannot allocate or pulse a compartment")

        var deposits: [LockerOperationRequest] = []
        for index in 0..<4 {
            let request = LockerOperationRequest(itemID: ids[index], kind: "deposit")
            deposits.append(request)
            let result = try await client.beginLockerOperation(request)
            try require(result.operation.id == request.requestID, "Operation identity changed")
            try require(result.operation.state == "awaiting_confirmation" && result.item.status == "deposit_pending",
                        "An opening pulse must not mark an item stored")
            try require(result.operation.compartmentID == String(format: "%02d", index + 1), "Incorrect slot allocation")
        }
        let reserved = try await client.lockers()
        try require(reserved.compartments.allSatisfy { $0.state == "reserved" } && reserved.operations.count == 4,
                    "All four in-progress deposits must reserve their slots")
        let pendingSearch = try await client.search(query: "蓝色钥匙扣")
        try require(pendingSearch.matches.isEmpty && pendingSearch.searchedCount == 0, "Pending deposits leaked into search")
        print("PASS allocation: four distinct operations reserve 01–04; pending deposits remain hidden")

        for request in deposits {
            let replay = try await client.beginLockerOperation(request)
            let lookup = try await client.lockerOperation(id: request.requestID.uppercased())
            try require(replay.operation == lookup.operation, "Replay and recovery lookup disagree")
        }
        let replayPulses = try pulseCount(audit)
        try require(replayPulses == 4, "Replays or read-only recovery emitted additional opening commands")
        try await expectConflict {
            _ = try await client.beginLockerOperation(LockerOperationRequest(itemID: ids[0], kind: "deposit"))
        }
        try await expectConflict {
            _ = try await client.beginLockerOperation(
                LockerOperationRequest(requestID: deposits[0].requestID, itemID: ids[1], kind: "deposit"))
        }
        print("PASS replay: stable IDs recover existing operations; changed payload/new active-item request rejected")

        let fifth = LockerOperationRequest(itemID: ids[4], kind: "deposit")
        try await expectConflict { _ = try await client.beginLockerOperation(fifth) }
        let fullPulses = try pulseCount(audit)
        try require(fullPulses == 4, "Full capacity must not send an opening command")
        print("PASS capacity: fifth deposit returns HTTP 409 without an extra pulse")

        for request in deposits {
            let result = try await client.completeLockerOperation(id: request.requestID)
            let repeatCompletion = try await client.completeLockerOperation(id: request.requestID)
            try require(result.operation.state == "completed" && result.item.isStored, "Deposit confirmation failed")
            try require(result.operation == repeatCompletion.operation, "Completion acknowledgement is not idempotent")
        }
        let stored = try await client.items(availableOnly: true)
        let matches = try await client.search(query: "蓝色钥匙扣")
        try require(Set(stored.items.map(\.id)) == Set(ids.prefix(4)) && stored.total == 4, "Public browsing contains wrong inventory")
        try require(Set(matches.matches.map(\.id)) == Set(ids.prefix(4)) && matches.searchedCount == 4,
                    "Search must contain exactly four stored items")
        let completedPulses = try pulseCount(audit)
        try require(completedPulses == 4, "Physical completion acknowledgements must never pulse")
        print("PASS placement: explicit completion occupies slots and publishes exactly four stored items")

        let retrieval = LockerOperationRequest(itemID: ids[0], kind: "retrieve")
        let opened = try await client.beginLockerOperation(retrieval)
        try require(opened.operation.compartmentID == "01" && opened.item.status == "retrieval_pending",
                    "Retrieval must target the item's original slot")
        let retrieving = try await client.lockers()
        try require(retrieving.compartments[0].state == "retrieving" && retrieving.compartments[0].itemID == ids[0],
                    "A retrieval pulse released the slot too early")
        let duringRetrieval = try await client.search(query: "蓝色钥匙扣")
        try require(duringRetrieval.searchedCount == 3 && !duringRetrieval.matches.contains { $0.id == ids[0] },
                    "An item being retrieved must not be offered again")
        _ = try await client.beginLockerOperation(retrieval)
        let retrievalPulses = try pulseCount(audit)
        try require(retrievalPulses == 5, "Retrieval replay opened the door twice")
        print("PASS retrieval: selected item's slot opens once and remains assigned until confirmation")

        let collected = try await client.completeLockerOperation(id: retrieval.requestID)
        _ = try await client.completeLockerOperation(id: retrieval.requestID)
        try require(collected.item.status == "collected" && collected.item.compartmentID == nil,
                    "Retrieval confirmation must mark collected and clear the slot assignment")
        let released = try await client.lockers()
        try require(released.compartments[0].state == "free" && released.compartments[0].itemID == nil,
                    "Retrieved compartment did not return to free")
        try await expectConflict {
            _ = try await client.beginLockerOperation(LockerOperationRequest(itemID: ids[0], kind: "retrieve"))
        }
        let reuse = try await client.beginLockerOperation(fifth)
        try require(reuse.operation.compartmentID == "01", "A previously full request did not reuse the released slot")
        _ = try await client.completeLockerOperation(id: fifth.requestID)
        let reusedSearch = try await client.search(query: "蓝色钥匙扣")
        try require(Set(reusedSearch.matches.map(\.id)) == Set(ids[1...4]), "Collected item remained searchable after slot reuse")
        print("PASS collection/reuse: confirmation frees 01; fifth item can use it; collected item stays hidden")

        let oldCompletion = try await client.completeLockerOperation(id: deposits[0].requestID)
        let afterOldCompletion = try await client.lockers()
        try require(oldCompletion.operation.state == "completed" && afterOldCompletion.compartments[0].itemID == ids[4],
                    "An old completion acknowledgement changed the new slot owner")
        try await expectConflict {
            _ = try await client.resolveLockerOperation(id: deposits[0].requestID, outcome: "empty")
        }
        print("PASS stale acknowledgement: old operations cannot free or overwrite a reused compartment")

        let cancelledRetrieval = LockerOperationRequest(itemID: ids[4], kind: "retrieve")
        _ = try await client.beginLockerOperation(cancelledRetrieval)
        let retained = try await client.resolveLockerOperation(id: cancelledRetrieval.requestID, outcome: "stored")
        try require(retained.item.isStored, "Staff's still-stored outcome must retain the item and slot")
        let staffRetrieval = LockerOperationRequest(itemID: ids[4], kind: "retrieve")
        _ = try await client.beginLockerOperation(staffRetrieval)
        let staffCollected = try await client.resolveLockerOperation(id: staffRetrieval.requestID, outcome: "collected")
        try require(staffCollected.item.status == "collected", "Staff collection reconciliation did not complete")
        let abandonedDeposit = LockerOperationRequest(itemID: ids[5], kind: "deposit")
        _ = try await client.beginLockerOperation(abandonedDeposit)
        let empty = try await client.resolveLockerOperation(id: abandonedDeposit.requestID, outcome: "empty")
        try require(empty.item.status == "recorded" && empty.item.compartmentID == nil,
                    "Empty deposit reconciliation must return the item to recorded")
        let actualDeposit = LockerOperationRequest(itemID: ids[5], kind: "deposit")
        _ = try await client.beginLockerOperation(actualDeposit)
        _ = try await client.resolveLockerOperation(id: actualDeposit.requestID, outcome: "stored")
        let final = try await client.lockers()
        try require(final.operations.isEmpty && final.compartments.allSatisfy { $0.state == "occupied" },
                    "Completed and reconciled operations left dangling reservations")
        let finalPulses = try pulseCount(audit)
        try require(finalPulses == 10, "Expected exactly ten explicit starts; resolution/replay must not pulse")
        print("PASS reconciliation: explicit stored/collected/empty outcomes keep item and slot states consistent")
        print("RESULT: 10 real HTTP workflow checks passed; exactly 10 simulated opening commands")
    }
}
