import SwiftUI

struct LockerAvailabilityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Storage compartments", systemImage: "square.grid.2x2.fill")
                    .font(.headline)
                Spacer(minLength: 8)
                if let status = store.lockerStatus, status.enabled {
                    Text("\(status.compartments.filter { $0.state == "free" }.count) available")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let status = store.lockerStatus {
                if status.enabled {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 12) {
                        ForEach(status.compartments, id: \.id) { compartment in
                            VStack(spacing: 8) {
                                Image(systemName: compartment.state == "free" ? "square.dashed" : "lock.fill")
                                    .font(.title3).accessibilityHidden(true)
                                Text(compartment.id).font(.title2.weight(.semibold).monospacedDigit())
                                Text(compartmentLabel(compartment.state))
                                    .font(.caption.weight(.medium)).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(compartment.state == "free" ? FoundStyle.accent : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 104).padding(.vertical, 10)
                            .background(compartment.state == "free" ? FoundStyle.soft : FoundStyle.background,
                                        in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Compartment \(compartment.id), \(compartmentLabel(compartment.state))")
                        }
                    }
                    if !status.compartments.contains(where: { $0.state == "free" }) {
                        Label("All compartments are in use. You can still find and collect an item.", systemImage: "tray.full")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if status.driver == "simulated" {
                        Label("Demo mode · physical doors are not connected", systemImage: "play.rectangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Storage is unavailable. Please ask station staff for help.", systemImage: "lock.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Label(store.isRefreshing ? "Checking compartment availability…" : "Compartment status is unavailable.",
                      systemImage: store.isRefreshing ? "arrow.clockwise" : "wifi.exclamationmark")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !store.isRefreshing {
                    Button("Check again", systemImage: "arrow.clockwise") {
                        Task { await store.refreshLockers() }
                    }.buttonStyle(.bordered).disabled(store.isLockerBusy)
                }
            }
        }.foundCard().accessibilityIdentifier("lockerAvailability")
    }

    private func compartmentLabel(_ state: String) -> String {
        switch state {
        case "free": "Available"
        case "reserved": "Being filled"
        case "occupied": "In use"
        case "retrieving": "Collecting"
        default: "Staff check"
        }
    }
}

struct LockerOperationPanel: View {
    let operation: LockerOperation
    var showsActions = true
    var compact = false
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var depositing: Bool { operation.kind == "deposit" }
    private var completed: Bool { operation.state == "completed" }

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            HStack(spacing: 8) {
                Image(systemName: completed ? "checkmark.circle.fill" : "door.left.hand.open")
                Text(completed ? (depositing ? "Item stored" : "Item collected") : "Your compartment")
            }.font(.headline).foregroundStyle(FoundStyle.accent)
            Text(operation.compartmentID)
                .font(.system(size: compact ? 64 : 88, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6).lineLimit(1)
                .foregroundStyle(FoundStyle.accent)
                .frame(maxWidth: .infinity).padding(.vertical, compact ? 4 : 8)
                .background(FoundStyle.soft, in: RoundedRectangle(cornerRadius: 24))
                .accessibilityLabel("Compartment \(operation.compartmentID)")
                .accessibilityIdentifier("assignedCompartment")
            if completed {
                Text(depositing ? "Thank you for keeping this item safe." : "You’re reunited. This compartment is now available again.")
                    .font(.title3.weight(.medium)).multilineTextAlignment(.center)
                if showsActions { LockerOperationAction(operation: operation) }
            } else if operation.state == "awaiting_confirmation" {
                Text(depositing ? "Place the item inside, then close the door." : "Take your item, then close the door.")
                    .font(.title3.weight(.medium)).multilineTextAlignment(.center)
                if store.requiresDoorFeedback {
                    LockerDoorFeedbackView(operation: operation)
                } else {
                    Text("An unlock request was sent. If the door did not open, ask station staff for help.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if showsActions { LockerOperationAction(operation: operation) }
            } else if operation.state == "actuating" {
                ProgressView("Sending the unlock request…")
                Text("Keep this screen open while the station checks the request.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if showsActions { LockerOperationAction(operation: operation) }
            } else {
                Label("Please ask staff to check this compartment.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.headline).multilineTextAlignment(.center)
                Text("The station could not confirm the unlock request. This compartment is held until staff check it.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let error = store.lockerError ?? operation.error {
                Notice(text: error, isError: true)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3), value: operation.state)
        .sensoryFeedback(.success, trigger: completed)
        .accessibilityIdentifier("lockerOperation")
    }
}

private struct LockerDoorFeedbackView: View {
    let operation: LockerOperation
    @Environment(AppStore.self) private var store

    private var state: AppStore.DoorFeedbackState { store.doorFeedbackState(for: operation) }
    private var title: String {
        switch state {
        case .closed: "Door closed"
        case .open: "Door not closed"
        case .manual, .checking: "Checking the door…"
        case .unavailable: "Door status unavailable"
        }
    }
    private var symbol: String {
        switch state {
        case .closed: "checkmark.circle.fill"
        case .open: "door.left.hand.open"
        case .manual, .checking: "door.left.hand.closed"
        case .unavailable: "wifi.exclamationmark"
        }
    }
    private var detail: String {
        switch state {
        case .closed:
            operation.kind == "deposit" ? "Confirm once the item is inside." : "Confirm once you have taken your item."
        case .open: "Close compartment \(operation.compartmentID) to continue."
        case .manual, .checking: "The station is reading the door sensor."
        case .unavailable: "Check the connection or ask station staff for help."
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(state == .closed ? FoundStyle.accent : state == .open ? Color.orange : Color.secondary)
                .frame(width: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(state == .closed ? FoundStyle.soft : FoundStyle.background,
                    in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lockerDoorStatus")
    }
}

/// Report pins this action outside its scrollable content; other screens use it inside their card.
struct LockerOperationAction: View {
    let operation: LockerOperation
    @Environment(AppStore.self) private var store
    private var depositing: Bool { operation.kind == "deposit" }
    private var confirmationTitle: String {
        if store.requiresDoorFeedback {
            return depositing ? "I’ve placed the item inside" : "I’ve taken my item"
        }
        return depositing ? "I’ve placed it inside & closed the door" : "I’ve taken my item & closed the door"
    }

    var body: some View {
        if operation.state == "completed" {
            PrimaryAction(title: "Finish & Return Home", symbol: "house.fill") { _ = store.endVisitorSession() }
                .accessibilityIdentifier("finishLockerVisit")
        } else if operation.state == "awaiting_confirmation" {
            PrimaryAction(title: confirmationTitle,
                          symbol: depositing ? "tray.and.arrow.down.fill" : "checkmark.circle.fill", busy: store.isLockerBusy) {
                let operationID = operation.id
                let visitor = store.visitorRevision
                let server = store.revision
                Task {
                    guard store.lockerOperation?.id == operationID, store.visitorRevision == visitor,
                          store.revision == server, !store.lockerNeedsStaff else { return }
                    await store.completeLockerOperation()
                }
            }
            .disabled(!store.canCompleteLockerOperation(operation))
            .multilineTextAlignment(.center)
            .accessibilityIdentifier(depositing ? "confirmItemStored" : "confirmItemCollected")
        } else if operation.state == "actuating" {
            Button("Check request status", systemImage: "arrow.clockwise") {
                Task { await store.refreshLockerOperation() }
            }.buttonStyle(.bordered).disabled(store.isLockerBusy)
        }
    }
}

/// Explicitly resume a persisted step without replaying an opening command.
struct LockerResumeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Page {
            VStack(spacing: 24) {
                Text("Finish the compartment step")
                    .font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
                Text("Complete this step before registering another item.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if store.isLockerBusy && store.lockerOperation == nil {
                    ProgressView("Checking the compartment…").padding(32)
                } else if let operation = store.lockerOperation {
                    LockerOperationPanel(operation: operation, showsActions: !store.lockerNeedsStaff)
                    if operation.state == "actuating" {
                        Button("Check again", systemImage: "arrow.clockwise") {
                            Task { await store.resumeLockerVisit() }
                        }.buttonStyle(.bordered).disabled(store.isLockerBusy)
                    }
                } else {
                    Notice(text: store.lockerError ?? "The station could not check this compartment yet.", isError: true)
                    PrimaryAction(title: "Check again", symbol: "arrow.clockwise", busy: store.isLockerBusy) {
                        Task { await store.resumeLockerVisit() }
                    }
                }
            }.frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .navigationTitle("Your compartment").navigationBarTitleDisplayMode(.inline)
        .modifier(VisitorNavigation())
    }
}

/// A current visit can finish its physical step even after returning from item details.
struct LockerVisitRecoveryView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if !store.lockerNeedsStaff && (store.hasPendingLocker || store.lockerOperation != nil) {
            VStack(alignment: .leading, spacing: 16) {
                if let item = store.lockerItem {
                    ItemCategoryLabel(title: item.title, primaryTag: item.recognition?.tags.first)
                        .font(.headline)
                }
                if let operation = store.lockerOperation {
                    LockerOperationPanel(operation: operation)
                } else if store.isLockerBusy {
                    ProgressView("Checking your compartment request…")
                } else {
                    Label("Finish your current collection", systemImage: "lock.open")
                        .font(.headline)
                    Text("Check the request before continuing. If its status remains unavailable, ask station staff for help.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    PrimaryAction(title: "Check request status", symbol: "arrow.clockwise") {
                        Task { await store.refreshLockerOperation() }
                    }
                    if let error = store.lockerError { Notice(text: error, isError: true) }
                }
            }.foundCard().accessibilityIdentifier("resumeLockerVisit")
        }
    }
}
