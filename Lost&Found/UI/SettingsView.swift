import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var address = ""
    @State private var checking = false
    @State private var message: String?
    @State private var failed = false
    @FocusState private var editing: Bool

    var body: some View {
        Page {
            PageHeading(title: "Settings",
                        subtitle: "Connect Found to your campus lost-and-found server.", symbol: "slider.horizontal.3")
            AdaptiveColumns {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        CardHeading(title: "Campus server", subtitle: "Where your item photos are saved.", symbol: "server.rack")
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server address").font(.subheadline.weight(.medium))
                            TextField("https://work123.local:8443", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($editing).disabled(checking)
                                .padding(12).background(FoundStyle.background, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("Server address").accessibilityIdentifier("serverAddress")
                        }
                        PrimaryAction(title: checking ? "Checking connection…" : "Save & check connection", symbol: "wifi", busy: checking) {
                            editing = false
                            Task { await saveAndCheck() }
                        }.disabled(checking || store.isSaving).accessibilityIdentifier("checkConnection")
                        if let message {
                            Notice(text: message, symbol: failed ? "exclamationmark.circle" : "checkmark.circle", isError: failed)
                                .accessibilityIdentifier("connectionResult")
                        }
                        Text("Connect this device and the server to the same network. Use the server’s HTTPS address; the address is saved on this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.foundCard()
                    VStack(alignment: .leading, spacing: 16) {
                        CardHeading(title: "Connection", subtitle: "The latest status from your server.", symbol: "network")
                        connectionRow("Server", value: store.connected ? "Connected" : "Not connected",
                                      symbol: store.connected ? "wifi" : "wifi.slash")
                        Divider()
                        connectionRow("AI tagging", value: store.connected ? (store.aiConfigured ? "Available" : "Unavailable") : "Unknown",
                                      symbol: "sparkles")
                        Divider()
                        connectionRow("Saved items", value: store.connected ? "\(store.total)" : "—", symbol: "tray.full")
                    }.foundCard()
                }
            } trailing: {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        CardHeading(title: "Getting connected", subtitle: "A few things to check on this device.", symbol: "checklist")
                        Label("Allow Local Network access when iOS asks.", systemImage: "wifi")
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Label("For the project server, install the campus CA certificate and enable full trust in iOS Settings.", systemImage: "checkmark.shield")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Settings → General → About → Certificate Trust Settings. The certificate must match the server address and be valid.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        #if targetEnvironment(simulator)
                        Notice(text: "Simulator: run the Python server on this Mac and use http://127.0.0.1:8080.", symbol: "desktopcomputer")
                        #endif
                    }.foundCard()
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeading(title: "Found", subtitle: "Less lost. More found.", symbol: "arrow.up.right")
                            .padding(.bottom, 12)
                        Text("A campus lost-and-found photo register. AI suggests tags and possible matches; campus staff verify collection.")
                        Label("Use a trusted campus network. The current server shares records with everyone who can access it.", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
                    }.foundCard()
                }
            }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .onAppear { address = store.serverAddress }
    }

    private func connectionRow(_ title: String, value: String, symbol: String) -> some View {
        LabeledContent {
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        } label: {
            Label(title, systemImage: symbol)
        }
        .font(.subheadline)
    }

    private func saveAndCheck() async {
        checking = true; message = nil; failed = false
        defer { checking = false }
        do {
            try store.changeServer(to: address)
            address = store.serverAddress
            try await store.client.health()
            await store.refresh()
            failed = !store.connected
            message = store.connected ? "Connected. Your server address is saved." : (store.listError ?? "The server responded, but items could not be loaded.")
        } catch {
            failed = true; message = error.localizedDescription
        }
    }
}
