import LocalAuthentication
import SwiftUI

struct StaffAccessView: View {
    let beginStaffReport: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authenticated = false
    @State private var authenticating = false
    @State private var authenticationError: String?
    @State private var context = LAContext()
    @State private var authenticationAttempt = UUID()
    @State private var confirmingDiscard = false
    @State private var reconciliation: LockerOperation?
    @State private var resolutionOutcome = ""
    @State private var confirmingReconciliation = false
    @State private var confirmingRetry = false

    var body: some View {
        NavigationStack {
            Group {
                if authenticated {
                    List {
                        Section("Station management") {
                            NavigationLink { SettingsView() } label: { Label("Connection & device setup", systemImage: "slider.horizontal.3") }
                            NavigationLink { ItemsView() } label: { Label("Saved items", systemImage: "tray.full") }
                            if !store.reportNeedsStaff {
                                Button {
                                    guard store.beginVisitorTask(.report) else { return }
                                    beginStaffReport()
                                } label: { Label("Register a station photo", systemImage: "photo.on.rectangle") }
                            }
                        }
                        if store.reportNeedsStaff {
                            Section {
                                Label("A report needs checking", systemImage: "exclamationmark.circle")
                                Text("A visitor left before a save could be confirmed. Retry uses the original report to avoid duplicates.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("Review & Retry") {
                                    guard store.resumePendingReport() else { return }
                                    beginStaffReport()
                                }.accessibilityIdentifier("staffRetryReport")
                                Button("Clear Local Pending Report", role: .destructive) { confirmingDiscard = true }
                            } footer: { Text("Clearing the local report does not remove an item already saved on the server.") }
                        }
                        lockerRecovery
                        Section {
                            Label("Public station", systemImage: "ipad.landscape")
                            Text("Use Guided Access to keep this iPad in Found. Keep the device passcode and enrolled biometrics restricted to staff.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 22) {
                        Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(FoundStyle.accent)
                        Text("Staff access").font(.title.bold())
                        Text("Authenticate with this device’s passcode, Touch ID or Face ID to manage the station.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if let authenticationError { Text(authenticationError).font(.subheadline).foregroundStyle(.red) }
                        Button { Task { await authenticate() } } label: {
                            if authenticating { ProgressView("Authenticating…") }
                            else { Label("Unlock Staff Tools", systemImage: "lock.open") }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(FoundStyle.buttonBackground)
                        .disabled(authenticating).accessibilityIdentifier("unlockStaff")
                    }.padding(32).frame(maxWidth: 500).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(authenticated ? "Staff tools" : "Staff access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .environment(\.staffToolsEnabled, authenticated)
        .tint(FoundStyle.accent)
        .onDisappear { invalidateAuthentication() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { invalidateAuthentication() }
        }
        .confirmationDialog("Clear this pending report?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Clear Local Report", role: .destructive) {
                guard authenticated, scenePhase == .active else { return }
                store.clearDraft()
            }
            Button("Keep Report", role: .cancel) {}
        } message: { Text("Check saved items first. The server may already have received this report. Clearing it removes the safe retry copy from this device.") }
        .confirmationDialog("Confirm the physical compartment check", isPresented: $confirmingReconciliation, titleVisibility: .visible) {
            Button(resolutionTitle) {
                guard authenticated, scenePhase == .active, let operation = reconciliation else { return }
                let outcome = resolutionOutcome
                let authorization = authenticationAttempt
                let visitor = store.visitorRevision
                let server = store.revision
                Task {
                    guard authenticated, authenticationAttempt == authorization, scenePhase == .active,
                          store.visitorRevision == visitor, store.revision == server else { return }
                    await store.resolveLockerOperation(operation, outcome: outcome)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only continue after checking compartment \(reconciliation?.compartmentID ?? ""). \(resolutionExplanation) This updates the records without opening a door.")
        }
        .confirmationDialog("Retry the pending unlock request?", isPresented: $confirmingRetry, titleVisibility: .visible) {
            Button("Retry the same request") {
                guard authenticated, scenePhase == .active else { return }
                let authorization = authenticationAttempt
                let visitor = store.visitorRevision
                let server = store.revision
                Task {
                    guard authenticated, authenticationAttempt == authorization, scenePhase == .active,
                          store.visitorRevision == visitor, store.revision == server else { return }
                    await store.retryLockerRequest()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check the compartment and keep the area clear first. The original request ID will be reused. If the server has not received it, this may send an unlock pulse; an existing request will not open the door again.")
        }
    }

    @ViewBuilder private var lockerRecovery: some View {
        Section {
            Button("Refresh compartment status", systemImage: "arrow.clockwise") {
                Task { await store.refreshLockers() }
            }.disabled(store.isLockerBusy)
            if store.hasPendingLocker {
                Text("This iPad has a pending compartment request. Check its server status before retrying or reconciling it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Check pending request", systemImage: "magnifyingglass") {
                    Task { await store.refreshLockerOperation() }
                }.disabled(store.isLockerBusy)
                Button("Retry the same request", systemImage: "arrow.clockwise.circle") {
                    confirmingRetry = true
                }.disabled(store.isLockerBusy)
            }
            ForEach(store.lockerStatus?.operations ?? [], id: \.id) { operation in
                VStack(alignment: .leading, spacing: 12) {
                    Label("Compartment \(operation.compartmentID)", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.headline)
                    Text(operation.kind == "deposit" ? "Unfinished storage" : "Unfinished collection")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let error = operation.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    if operation.state != "actuating" {
                        Button(operation.kind == "deposit" ? "Item is inside · mark stored" : "Item was collected · mark collected") {
                            prepareResolution(operation, outcome: operation.kind == "deposit" ? "stored" : "collected")
                        }.disabled(store.isLockerBusy)
                        Button(operation.kind == "deposit" ? "Compartment is empty · release it" : "Item is still inside · keep stored") {
                            prepareResolution(operation, outcome: operation.kind == "deposit" ? "empty" : "stored")
                        }.disabled(store.isLockerBusy)
                    } else {
                        Text("The unlock request is running. Refresh its status before making changes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            if let error = store.lockerError { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Label("Compartment recovery", systemImage: "square.grid.2x2")
        } footer: {
            Text("Inspect the item and close the door before confirming. A compartment remains unavailable until the interrupted operation is resolved.")
        }
    }

    private func prepareResolution(_ operation: LockerOperation, outcome: String) {
        guard authenticated, scenePhase == .active else { return }
        reconciliation = operation
        resolutionOutcome = outcome
        confirmingReconciliation = true
    }

    private var resolutionTitle: String {
        switch resolutionOutcome {
        case "stored": "Confirm item is stored"
        case "collected": "Confirm item was collected"
        default: "Confirm compartment is empty"
        }
    }

    private var resolutionExplanation: String {
        switch resolutionOutcome {
        case "stored": "The item must be inside and the door closed."
        case "collected": "The item must be removed and the door closed."
        default: "The compartment must be empty and its door closed."
        }
    }

    @MainActor private func authenticate() async {
        context.invalidate()
        context = LAContext()
        let attempt = UUID()
        authenticationAttempt = attempt
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authenticationError = "Device authentication is unavailable. Staff must set up a device passcode before using these tools."
            return
        }
        authenticating = true
        authenticationError = nil
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Manage this lost-and-found station")
            guard authenticationAttempt == attempt else { return }
            authenticated = success
            authenticating = false
        } catch {
            guard authenticationAttempt == attempt else { return }
            authenticationError = "Staff access remains locked. You can try again."
            authenticating = false
        }
    }

    private func invalidateAuthentication() {
        authenticationAttempt = UUID()
        context.invalidate()
        authenticating = false
        authenticated = false
        confirmingDiscard = false
        confirmingReconciliation = false
        confirmingRetry = false
        reconciliation = nil
    }
}
