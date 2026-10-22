import SwiftUI

struct FindView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editing: Bool
    @Namespace private var itemTransition
    @State private var voice = VoiceInputController()
    @State private var showsKeyboard = false
    @State private var isVisible = false

    var body: some View {
        Page {
            PageHeading(title: "What did you lose?",
                        subtitle: "Describe it out loud. A few details can help us find it.",
                        symbol: "magnifyingglass")
            AdaptiveColumns {
                VStack(alignment: .leading, spacing: 20) {
                    queryCard
                    NavigationLink { ItemsView() } label: {
                        Label("Browse stored items", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("browseItems")
                    Notice(text: "Check the photo and details. Select your item to open its compartment, then confirm once you’ve collected it.",
                           symbol: "lock.open")
                }
            } trailing: {
                VStack(alignment: .leading, spacing: 20) {
                    LockerVisitRecoveryView()
                    if let error = store.searchError {
                        Notice(text: "\(error) Your description is still here; you can try again.", isError: true)
                    }
                    if store.isSearching {
                        VStack(spacing: 18) {
                            IconBadge(symbol: "sparkle.magnifyingglass", size: 64)
                            ProgressView("Looking through saved items…")
                            Text("Comparing your description with item tags and notes.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 32).foundCard().transition(.opacity)
                    } else if let result = store.searchResult {
                        results(result)
                    } else {
                        searchGuidance
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3), value: store.isSearching)
            }
        }
        .navigationDestination(for: SearchMatch.self) { match in
            ItemDetailView(originalItem: match.item, matchReason: match.reason)
                .modifier(ItemDetailTransition(id: match.item.id, namespace: itemTransition))
        }
        .modifier(VisitorNavigation())
        .navigationTitle("Find an item").navigationBarTitleDisplayMode(.inline)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; voice.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { voice.cancel() } }
        .onChange(of: store.visitorRevision) { _, _ in voice.cancel() }
        .onChange(of: store.revision) { _, _ in voice.cancel() }
        .onChange(of: store.query) { _, text in
            store.query = limitedText(text, to: 500)
            store.clearSearchResults()
        }
    }

    private var queryCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 18) {
            if (showsKeyboard || !store.query.isEmpty) && !voice.isActive {
                compactVoiceInput
            } else {
                voiceInput
            }
            if let message = voice.errorMessage {
                Notice(text: message, isError: true)
            }
            if showsKeyboard || !store.query.isEmpty {
                Divider()
                Label("Your description", systemImage: "text.alignleft").font(.headline)
                TextField("e.g. A white bottle with a green label", text: $store.query, axis: .vertical)
                    .lineLimit(3...6).padding(18)
                    .background(FoundStyle.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(editing ? FoundStyle.accent.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1))
                    .focused($editing).disabled(store.isSearching || voice.isActive)
                    .accessibilityLabel("Item description").accessibilityIdentifier("searchQuery")
                HStack(alignment: .top, spacing: 12) {
                    Text("Review or edit, then find matches.")
                    Spacer(minLength: 0)
                    Text("\(store.query.unicodeScalars.count)/500").monospacedDigit().fixedSize()
                }.font(.caption).foregroundStyle(.secondary)
                PrimaryAction(title: store.isSearching ? "Looking for matches…" : "Find matches",
                              symbol: "magnifyingglass", busy: store.isSearching) {
                    editing = false
                    Task { await store.search() }
                }
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching || voice.isActive)
                .accessibilityIdentifier("findMatches")
            }
        }.foundCard()
    }

    private var compactVoiceInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: microphoneTapped) {
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill").font(.title2)
                        .foregroundStyle(.white).frame(width: 48, height: 48)
                        .background(FoundStyle.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Record a new description").font(.headline).foregroundStyle(.primary)
                        Text("Speak for up to 30 seconds").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(StationPressStyle()).disabled(store.isSearching)
                .accessibilityIdentifier("voiceInput")
                .accessibilityHint("Replaces the description after you finish speaking.")
            Text("Audio is sent to Alibaba Cloud for transcription.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var voiceInput: some View {
        VStack(spacing: 16) {
            Button(action: microphoneTapped) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(FoundStyle.accent.opacity(0.08)).frame(width: 116, height: 116)
                        Circle().fill(FoundStyle.accent).frame(width: 92, height: 92)
                        if voice.phase == .requestingPermission || voice.phase == .transcribing {
                            ProgressView().tint(.white).controlSize(.large)
                        } else {
                            Image(systemName: voice.phase == .recording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                        }
                    }
                    Text(voiceTitle).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(StationPressStyle())
            .disabled(store.isSearching || voice.phase == .requestingPermission || voice.phase == .transcribing)
            .accessibilityLabel(voice.phase == .recording ? "Stop recording and transcribe" : voiceTitle)
            .accessibilityHint(voice.phase == .recording ? "Converts your recording into an editable description." : "Records up to thirty seconds. Tap again when you have finished speaking.")
            .accessibilityIdentifier("voiceInput")

            if voice.phase == .recording {
                HStack(spacing: 12) {
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(0..<7) { index in
                            Capsule().fill(FoundStyle.accent)
                                .frame(width: 4, height: 5 + 23 * voice.level * (1 - Double(abs(index - 3)) * 0.2))
                        }
                    }.frame(height: 28).accessibilityHidden(true)
                    Text("\(Int(voice.elapsed))s / 30s").monospacedDigit().font(.subheadline)
                }
                Text("Listening… Tap the stop button when you’re done.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text(voice.phase == .transcribing ? "Turning your voice into an editable description…" : "The item, its color, and one distinctive detail.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            if voice.isActive {
                Button("Cancel", systemImage: "xmark") { voice.cancel(); store.recordVisitorActivity() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).frame(minHeight: 44)
                    .accessibilityIdentifier("cancelVoiceInput")
            } else {
                Button(store.query.isEmpty ? "Type instead" : "Edit description", systemImage: "keyboard") {
                    showsKeyboard = true
                    editing = true
                    store.recordVisitorActivity()
                }.buttonStyle(.bordered).buttonBorderShape(.capsule).frame(minHeight: 44)
                    .disabled(store.isSearching).accessibilityIdentifier("typeDescription")
            }
            Text("Up to 30 seconds. Audio is sent to Alibaba Cloud for transcription.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 4)
    }

    private var voiceTitle: String {
        switch voice.phase {
        case .idle: store.query.isEmpty ? "Tap to describe your item" : "Record a new description"
        case .requestingPermission: "Allow microphone access"
        case .recording: "Done speaking"
        case .transcribing: "Transcribing…"
        }
    }

    private func microphoneTapped() {
        editing = false
        store.recordVisitorActivity()
        if voice.phase == .recording { voice.finish(); return }
        let visitor = store.visitorRevision
        let server = store.revision
        let previousQuery = store.query
        let api = store.client
        Task {
            guard isVisible, scenePhase == .active, store.visitorRevision == visitor,
                  store.revision == server, store.selectedTab == .find else { return }
            await voice.start(transcribe: { data in try await api.transcribe(audio: data) }) { text in
                guard isVisible, scenePhase == .active else { return }
                if store.acceptTranscription(text, replacing: previousQuery, visitorRevision: visitor, serverRevision: server) {
                    showsKeyboard = true
                }
            }
        }
    }

    private var searchGuidance: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 34, weight: .regular)).foregroundStyle(FoundStyle.searchAccent)
                    .frame(width: 64, height: 64).background(FoundStyle.searchAccent.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Small details help").font(.title3.weight(.semibold))
                    Text("Start with one or two things.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            clue("The item", example: "A bottle, a backpack, a set of keys…", symbol: "backpack.fill")
            clue("Its color", example: "Blue fabric, a green label, a silver case…", symbol: "paintpalette.fill")
            clue("One distinctive detail", example: "A sticker, a shape, a familiar pattern…", symbol: "tag.fill")
            Divider()
            Label("Possible matches will appear here.", systemImage: "photo.on.rectangle")
                .font(.footnote).foregroundStyle(.secondary)
        }.foundCard()
    }

    private func clue(_ title: String, example: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(example).font(.footnote).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func results(_ result: SearchResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if result.matches.isEmpty {
                ContentUnavailableView(result.searchedCount == 0 ? "No stored items to search" : "No matches this time",
                                       systemImage: "magnifyingglass",
                                       description: Text(result.searchedCount == 0 ? "Items appear here after they have been identified and placed in a compartment." : "Try a different detail, or check back after more items are stored."))
                    .foundCard()
            } else {
                Label("\(result.matches.count) possible \(result.matches.count == 1 ? "match" : "matches")", systemImage: "square.stack.3d.up")
                    .font(.title2.weight(.semibold))
                ForEach(result.matches) { match in
                    NavigationLink(value: match) {
                        VStack(alignment: .leading, spacing: 14) {
                            ItemSummary(item: match.item, transitionNamespace: itemTransition)
                            Label(match.reason, systemImage: "sparkles")
                                .font(.subheadline).foregroundStyle(.primary).padding(.horizontal, 20).padding(.bottom, 16)
                        }.background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(StationPressStyle())
                }
            }
            if result.pendingCount > 0 {
                Notice(text: "\(result.pendingCount) untagged \(result.pendingCount == 1 ? "item was" : "items were") not included in this search.", symbol: "tag.slash")
            }
        }.accessibilityIdentifier("searchResults")
    }

}
