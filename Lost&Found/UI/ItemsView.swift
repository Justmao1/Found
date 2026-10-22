import SwiftUI

struct ItemsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.staffToolsEnabled) private var staffToolsEnabled
    @Namespace private var itemTransition
    @State private var selectedItem: FoundItem?
    private var visibleItems: [FoundItem] {
        staffToolsEnabled ? store.items : store.availableItems
    }

    var body: some View {
        Page {
            PageHeading(title: staffToolsEnabled ? "Station records" : "Stored items",
                        subtitle: "Browse photos and details to spot something familiar.", symbol: "square.grid.2x2")
            if !staffToolsEnabled { LockerVisitRecoveryView() }
            Label("\(visibleItems.count) \(staffToolsEnabled ? "saved" : "stored") \(visibleItems.count == 1 ? "item" : "items")", systemImage: "tray.full")
                .font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(FoundStyle.accent)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(FoundStyle.soft, in: Capsule())
            if let error = store.listError {
                Notice(text: "\(error)\(store.items.isEmpty ? "" : " Showing the last loaded items.")", isError: true)
                Button { Task { await store.refresh() } } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered)
            }
            if let message = store.statusMessage { Notice(text: message, symbol: "sparkles") }
            if store.isRefreshing && visibleItems.isEmpty {
                ProgressView("Loading items…").frame(maxWidth: .infinity).padding(40)
            } else if visibleItems.isEmpty && store.listError == nil {
                ContentUnavailableView {
                    Label("A fresh start", systemImage: "tray")
                } description: {
                    Text("There are no items ready for collection. Stored items will appear here once their placement is confirmed.")
                } actions: {
                    if !staffToolsEnabled && !store.reportNeedsStaff {
                        Button { _ = store.beginVisitorTask(.report) } label: {
                            Label("Report an item", systemImage: "camera")
                        }.buttonStyle(.borderedProminent).tint(FoundStyle.buttonBackground)
                    }
                }.foundCard()
            } else {
                if staffToolsEnabled && store.total > store.items.count {
                    Text("Showing the latest \(store.items.count) of \(store.total) items. Find searches all tagged items.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(visibleItems) { item in
                        Button { selectedItem = item } label: {
                            ItemSummary(item: item, transitionNamespace: itemTransition)
                        }.buttonStyle(StationPressStyle())
                    }
                }
            }
        }
        .navigationDestination(item: $selectedItem) { item in
            ItemDetailView(originalItem: item)
                .modifier(ItemDetailTransition(id: item.id, namespace: itemTransition))
        }
        .refreshable { await store.refresh() }
        .modifier(VisitorNavigation())
        .navigationTitle("Items").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }.disabled(store.isRefreshing).accessibilityLabel("Refresh items")
            }
        }
    }
}

struct ItemDetailView: View {
    let originalItem: FoundItem
    var matchReason: String?
    @Environment(AppStore.self) private var store
    @Environment(\.staffToolsEnabled) private var staffToolsEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPhoto = false
    @State private var confirmingRetrieval = false
    @State private var retrievalAttempted = false
    private var item: FoundItem {
        if store.lockerItem?.id == originalItem.id, let current = store.lockerItem { return current }
        return store.items.first { $0.id == originalItem.id } ?? originalItem
    }
    private var operation: LockerOperation? {
        guard !store.lockerNeedsStaff, store.lockerOperation?.itemID == originalItem.id else { return nil }
        return store.lockerOperation
    }
    private var identifying: Bool { item.isPending || store.recognizing.contains(item.id) }
    private var awaitingRequest: Bool {
        retrievalAttempted && store.hasPendingLocker && !store.lockerNeedsStaff && store.lockerItem?.id == originalItem.id
    }
    private var hasActiveCollection: Bool { operation != nil || awaitingRequest }

    var body: some View {
        ScrollViewReader { scroll in
            Page {
                AdaptiveColumns {
                    VStack(alignment: .leading, spacing: 16) {
                        CardHeading(title: "Item photo", subtitle: "Tap the photo for a closer look.", symbol: "photo")
                        Button { showingPhoto = true } label: {
                            ItemPhoto(item: item, api: store.client, height: 320, fit: true)
                        }.buttonStyle(.plain).accessibilityHint("Open full photo")
                    }.foundCard()
                } trailing: {
                    VStack(alignment: .leading, spacing: 20) {
                        if hasActiveCollection {
                            collectionActions.id("collectionStep")
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            ItemCategoryLabel(title: item.title, primaryTag: item.recognition?.tags.first)
                                .font(.title.weight(.semibold))
                            Label("Registered · \(item.dateLabel)", systemImage: "calendar")
                                .font(.footnote).foregroundStyle(FoundStyle.accent)
                            if let compartment = item.compartmentID {
                                Label("Compartment \(compartment)", systemImage: "square.grid.2x2.fill")
                                    .font(.headline).foregroundStyle(FoundStyle.accent)
                            }
                            if !item.note.isEmpty {
                                Divider()
                                Label("Finder’s note", systemImage: "text.bubble").font(.subheadline.weight(.semibold))
                                Text(item.note).textSelection(.enabled)
                            }
                            if let reason = matchReason { Notice(text: reason, symbol: "sparkles") }
                        }.foundCard()
                        VStack(alignment: .leading, spacing: 16) {
                            CardHeading(title: "Item tags", subtitle: "Details to help you recognize the item.", symbol: "tag")
                            if let tags = item.recognition?.tags, !tags.isEmpty {
                                TagList(tags: tags)
                                Text("Generated by AI. Check these details against the photo.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if identifying {
                                ProgressView("Identifying this item…")
                                Text("Your photo is saved. Tags will appear here automatically.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text(store.aiConfigured ? "Your photo is saved, but tags are unavailable." : "Tagging is not enabled on this server. Your photo is saved.")
                                    .foregroundStyle(.secondary)
                                if staffToolsEnabled {
                                    Button { Task { await store.retryRecognition(for: item) } } label: {
                                        Label("Retry tagging", systemImage: "arrow.clockwise")
                                    }.buttonStyle(.bordered).disabled(!store.aiConfigured)
                                }
                            }
                            if let error = store.recognitionErrors[item.id] { Notice(text: error, isError: true) }
                        }.foundCard()
                        if !hasActiveCollection { collectionActions }
                    }
                }
            }
            .onChange(of: hasActiveCollection) { _, active in
                guard active else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                    scroll.scrollTo("collectionStep", anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let operation, ["awaiting_confirmation", "actuating", "completed"].contains(operation.state) {
                LockerOperationAction(operation: operation)
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background {
                        if reduceTransparency { FoundStyle.background }
                        else { Rectangle().fill(.regularMaterial) }
                    }
            }
        }
        .refreshable { await store.refresh() }
        .modifier(VisitorNavigation())
        .navigationTitle("Item details").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Is this your item?", isPresented: $confirmingRetrieval, titleVisibility: .visible) {
            Button("Yes, open compartment \(item.compartmentID ?? "")") {
                retrievalAttempted = true
                let candidate = item
                let visitor = store.visitorRevision
                let server = store.revision
                Task {
                    guard store.visitorRevision == visitor, store.revision == server else { return }
                    await store.beginRetrieval(for: candidate)
                }
            }
            Button("Keep looking", role: .cancel) {}
        } message: {
            Text("Confirm that the photo and identifying details match your item. Its compartment will be unlocked for collection.")
        }
        .sheet(isPresented: $showingPhoto) {
            NavigationStack {
                GeometryReader { geometry in
                    ItemPhoto(item: item, api: store.client, height: max(100, geometry.size.height - 32), fit: true).padding(16)
                }
                .modifier(VisitorSessionOverlay())
                .navigationTitle("Item photo").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPhoto = false } } }
            }
        }
    }

    @ViewBuilder private var collectionActions: some View {
        if let operation {
            LockerOperationPanel(operation: operation, showsActions: false).foundCard()
        } else if awaitingRequest {
            VStack(alignment: .leading, spacing: 16) {
                if store.isLockerBusy {
                    ProgressView("Requesting your compartment…")
                } else {
                    Text("The request needs checking before you continue.").font(.headline)
                    PrimaryAction(title: "Check request status", symbol: "arrow.clockwise") {
                        Task { await store.refreshLockerOperation() }
                    }
                }
                if let error = store.lockerError { Notice(text: error, isError: true) }
            }.foundCard()
        } else if item.isStored && store.lockerStatus?.enabled == true {
            VStack(alignment: .leading, spacing: 16) {
                CardHeading(title: "Ready to collect?", subtitle: "Compare the photo and details before opening the compartment.", symbol: "lock.open")
                PrimaryAction(title: "This is my item", symbol: "hand.raised.fill", busy: store.isLockerBusy) {
                    confirmingRetrieval = true
                    store.recordVisitorActivity()
                }.disabled(store.isLockerBusy || store.hasPendingLocker || store.lockerNeedsStaff)
                    .accessibilityIdentifier("claimItem")
                if retrievalAttempted, let error = store.lockerError { Notice(text: error, isError: true) }
            }.foundCard()
        } else {
            Notice(text: item.status == "collected" ? "This item has already been collected." : "This item is not ready for self-service collection. Please ask station staff for help.",
                   symbol: item.status == "collected" ? "checkmark.circle" : "person.crop.circle.badge.exclamationmark")
        }
    }
}
