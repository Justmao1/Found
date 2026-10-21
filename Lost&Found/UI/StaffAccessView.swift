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
            Button("Clear Local Report", role: .destructive) { store.clearDraft() }
            Button("Keep Report", role: .cancel) {}
        } message: { Text("Check saved items first. The server may already have received this report. Clearing it removes the safe retry copy from this device.") }
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
    }
}
