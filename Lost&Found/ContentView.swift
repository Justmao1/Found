import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingStaff = false
    @State private var staffReport = false
    @State private var lastInteraction = Date()

    var body: some View {
        NavigationStack {
            switch store.selectedTab {
            case .home, .settings:
                StationHomeView { showingStaff = true; lastInteraction = Date() }
            case .report:
                ReportView()
            case .find:
                FindView()
            case .items:
                ItemsView()
            }
        }
        .stationEntrance()
        .environment(\.staffToolsEnabled, staffReport)
        .modifier(VisitorSessionOverlay())
        .id("\(store.revision)-\(store.visitorRevision)")
        .background(StationBackdrop())
        .tint(FoundStyle.accent)
        .background(StationActivityMonitor {
            lastInteraction = Date()
            // The warning's buttons must remain present until touch-up.
            if store.idleSecondsRemaining == nil { store.recordVisitorActivity() }
        })
        .sheet(isPresented: $showingStaff) {
            StaffAccessView {
                staffReport = true
                showingStaff = false
            }
        }
        .onChange(of: store.selectedTab) { _, tab in
            if tab == .home { staffReport = false }
        }
        .onChange(of: store.note) { _, _ in store.recordVisitorActivity() }
        .onChange(of: store.query) { _, _ in store.recordVisitorActivity() }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            if phase == .background {
                showingStaff = false
                _ = store.endVisitorSession()
            }
        }
        .onChange(of: store.isSaving) { _, saving in
            if !saving && scenePhase == .background { _ = store.endVisitorSession() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = scenePhase == .active }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            store.checkVisitorInactivity()
            await store.refresh()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if showingStaff {
                    if Date().timeIntervalSince(lastInteraction) >= 120 { showingStaff = false }
                } else {
                    store.checkVisitorInactivity()
                }
            }
        }
        .task(id: "\(scenePhase)-\(store.hasPendingItems)-\(store.revision)") {
            guard scenePhase == .active, store.hasPendingItems else { return }
            while !Task.isCancelled && store.hasPendingItems {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard !Task.isCancelled else { return }
                await store.refresh()
            }
        }
    }
}

#Preview { ContentView().environment(AppStore()) }
