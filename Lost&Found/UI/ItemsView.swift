import SwiftUI

struct ItemsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.staffToolsEnabled) private var staffToolsEnabled
    @Namespace private var itemTransition

    var body: some View {
        Page {
            PageHeading(title: "Saved items",
                        subtitle: "Browse photos and details to spot something familiar.", symbol: "square.grid.2x2")
            Label("\(store.total) saved \(store.total == 1 ? "item" : "items")", systemImage: "tray.full")
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
            if store.isRefreshing && store.items.isEmpty {
                ProgressView("Loading items…").frame(maxWidth: .infinity).padding(40)
            } else if store.items.isEmpty && store.listError == nil {
                ContentUnavailableView {
                    Label("A fresh start", systemImage: "tray")
                } description: {
                    Text("No items have been reported yet. Save a photo to help someone find what they lost.")
                } actions: {
                    if !staffToolsEnabled && !store.reportNeedsStaff {
                        Button { _ = store.beginVisitorTask(.report) } label: {
                            Label("Report an item", systemImage: "camera")
                        }.buttonStyle(.borderedProminent).tint(FoundStyle.buttonBackground)
                    }
                }.foundCard()
            } else {
                if store.total > store.items.count {
                    Text("Showing the latest \(store.items.count) of \(store.total) items. Find searches all tagged items.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(store.items) { item in
                        NavigationLink {
                            ItemDetailView(originalItem: item)
                                .modifier(ItemDetailTransition(id: item.id, namespace: itemTransition))
                        } label: {
                            ItemSummary(item: item, transitionNamespace: itemTransition)
                        }.buttonStyle(StationPressStyle())
                    }
                }
            }
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
    @State private var showingPhoto = false
    private var item: FoundItem { store.items.first { $0.id == originalItem.id } ?? originalItem }
    private var identifying: Bool { item.isPending || store.recognizing.contains(item.id) }

    var body: some View {
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
                    VStack(alignment: .leading, spacing: 16) {
                        ItemCategoryLabel(title: item.title, primaryTag: item.recognition?.tags.first)
                            .font(.title.weight(.semibold))
                        Label("Photo saved · \(item.dateLabel)", systemImage: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(FoundStyle.accent)
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
                    Notice(text: "Please ask campus staff to verify the item before collecting it. Photo registration does not confirm locker storage.",
                           symbol: "person.crop.circle.badge.checkmark")
                }
            }
        }
        .refreshable { await store.refresh() }
        .modifier(VisitorNavigation())
        .navigationTitle("Item details").navigationBarTitleDisplayMode(.inline)
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
}
