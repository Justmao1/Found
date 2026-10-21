import SwiftUI

struct ReportEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.staffToolsEnabled) private var staffToolsEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var photo: Data
    @State private var savedItem: FoundItem?
    @State private var photoSource: ReportPhotoSource?
    @State private var importing = false
    @State private var confirmationAppeared = false
    @FocusState private var editingNote: Bool
    @AccessibilityFocusState private var statusFocused: Bool

    init(photo: Data) {
        _photo = State(initialValue: photo)
    }

    private var locked: Bool { store.isSaving || store.submission != nil }
    private var busy: Bool { store.isSaving || importing || photoSource != nil }
    private var stateAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.9)
    }
    private var currentSavedItem: FoundItem? {
        guard let savedItem else { return nil }
        return store.items.first { $0.id == savedItem.id } ?? savedItem
    }

    var body: some View {
        @Bindable var store = store
        let serverRevision = store.revision
        let visitorRevision = store.visitorRevision
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    Form {
                        Section {
                            photoPreview(height: min(320, max(180, geometry.size.height * 0.39)))
                                .listRowInsets(EdgeInsets())
                                .id("reportPhoto")
                        }
                        if let item = currentSavedItem {
                            itemTags(item)
                            receipt(item)
                                .transition(.opacity)
                        } else {
                            Section {
                                TextField("e.g. Found near the library entrance", text: $store.note, axis: .vertical)
                                    .lineLimit(3...5).focused($editingNote).disabled(locked || importing)
                                    .accessibilityLabel("Item notes").accessibilityIdentifier("itemNote")
                                    .onChange(of: store.note) { _, value in store.note = limitedText(value, to: 200) }
                            } header: {
                                Label("A helpful detail", systemImage: "text.alignleft")
                            } footer: {
                                HStack(alignment: .top) {
                                    Text("Optional. Add a location or something distinctive.")
                                    Spacer(minLength: 12)
                                    Text("\(store.note.unicodeScalars.count)/200").monospacedDigit()
                                }
                            }
                            if let error = store.saveError {
                                Section {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.title2).foregroundStyle(.red).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text("Couldn’t confirm the save").font(.headline)
                                                .accessibilityFocused($statusFocused)
                                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 4)
                                    Text("Your photo and note are kept. Retrying won’t create a duplicate report.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }.id("reportSaveError").accessibilityIdentifier("reportSaveError")
                            }
                            Section {
                                HStack(spacing: 12) {
                                    IconBadge(symbol: "sparkles", size: 38)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Automatic item tags").font(.subheadline.weight(.semibold))
                                        Text("After saving, you’ll see the recognized tags below your photo.")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 3)
                            } footer: {
                                Text("Saving uploads this photo to your campus server. If AI tagging is enabled, it is also sent to Alibaba Bailian. You won’t need to wait for tags to finish.")
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollContentBackground(.hidden)
                    .background(FoundStyle.background)
                    .animation(stateAnimation, value: savedItem?.id)
                    .onChange(of: store.saveError) { _, error in
                        guard error != nil else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            scroll.scrollTo("reportSaveError", anchor: .center)
                        }
                        statusFocused = true
                    }
                    .onChange(of: savedItem?.id) { _, identifier in
                        guard identifier != nil else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            scroll.scrollTo("reportPhoto", anchor: .top)
                        }
                        statusFocused = true
                    }
                }
            }
            .navigationTitle(savedItem == nil ? "Review your photo" : "Item saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if savedItem == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        EndVisitButton().disabled(busy)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Finish") { _ = store.endVisitorSession() }.fontWeight(.semibold).accessibilityIdentifier("finishReport")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editingNote = false }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    if currentSavedItem != nil {
                        PrimaryAction(title: "Finish & Return Home", symbol: "house.fill") { _ = store.endVisitorSession() }
                            .accessibilityIdentifier("finishSavedVisit")
                    } else if store.isSaving {
                        HStack(spacing: 12) {
                            ProgressView().tint(FoundStyle.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Saving your item…").font(.headline)
                                Text("Keep this screen open.").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18).frame(minHeight: 64)
                        .background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("saveItemProgress")
                    } else {
                        PrimaryAction(title: store.submission == nil ? "Save Item" : "Retry Saving",
                                      symbol: store.submission == nil ? "checkmark" : "arrow.clockwise") {
                            editingNote = false
                            Task {
                                if let item = await store.savePhoto() {
                                    withAnimation(stateAnimation) { savedItem = item }
                                    await store.refresh()
                                }
                            }
                        }
                        .disabled(busy || store.photoData == nil)
                        .accessibilityIdentifier("saveItem")
                    }
                }
                .frame(minHeight: 64)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .background {
                    if reduceTransparency { FoundStyle.background }
                    else { Rectangle().fill(.regularMaterial) }
                }
                .animation(stateAnimation, value: store.isSaving)
                .animation(stateAnimation, value: savedItem?.id)
            }
        }
        .tint(FoundStyle.accent)
        .interactiveDismissDisabled(true)
        .modifier(VisitorSessionOverlay())
        .sensoryFeedback(.success, trigger: savedItem?.id)
        .modifier(ReportPhotoAcquisition(source: $photoSource, importing: $importing) { data in
            guard store.acceptPhoto(data, visitorRevision: visitorRevision, serverRevision: serverRevision) else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { photo = data }
        })
    }

    private func photoPreview(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            FoundStyle.surface
            if let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(savedItem == nil ? "Photo to report" : "Saved item photo")
            }
            if importing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing photo…").font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16).frame(minHeight: 48)
                .stationFloatingControl()
                .padding(12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reportProgress")
            } else if savedItem == nil && !locked {
                HStack {
                    Spacer()
                    if staffToolsEnabled {
                        Menu {
                            Button { editingNote = false; photoSource = .camera } label: { Label("Retake Photo", systemImage: "camera") }
                            Button { editingNote = false; photoSource = .library } label: { Label("Choose Station Photo", systemImage: "photo.on.rectangle") }
                        } label: { photoChangeLabel }
                    } else {
                        Button { editingNote = false; photoSource = .camera } label: { photoChangeLabel }
                            .accessibilityIdentifier("retakeReportPhoto")
                    }
                }.padding(12)
            }
        }
        .frame(height: height).clipped()
    }

    private var photoChangeLabel: some View {
        Label(staffToolsEnabled ? "Change Photo" : "Retake Photo", systemImage: "camera.rotate")
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
            .stationFloatingControl()
    }

    private func itemTags(_ item: FoundItem) -> some View {
        Section {
            if let tags = item.recognition?.tags, !tags.isEmpty {
                TagList(tags: tags)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("reportRecognizedTags")
            } else if item.isPending || store.recognizing.contains(item.id) {
                HStack(spacing: 12) {
                    ProgressView().tint(FoundStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recognizing your item…").font(.subheadline.weight(.medium))
                        Text("Tags will appear here automatically. Your photo is already saved.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6).accessibilityIdentifier("reportTaggingProgress")
            } else {
                Label(store.aiConfigured ? "Tags aren’t available yet. Your photo is saved." : "Automatic tagging is unavailable. Your photo is saved.",
                      systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.aiConfigured {
                    Button {
                        let visitor = store.visitorRevision
                        let server = store.revision
                        store.recordVisitorActivity()
                        Task {
                            guard store.visitorRevision == visitor, store.revision == server,
                                  store.lastSaved?.id == item.id else { return }
                            await store.retryRecognition(for: item)
                        }
                    } label: {
                        Label("Retry tagging", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("retryReportTagging")
                }
            }
            if let error = store.recognitionErrors[item.id] {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("reportTaggingError")
            }
        } header: {
            Label("Recognized tags", systemImage: "tag.fill")
        } footer: {
            Text("AI-generated details help the owner find this item. You can finish whenever you’re ready.")
        }
    }

    private func receipt(_ item: FoundItem) -> some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FoundStyle.accent)
                    .symbolEffect(.bounce, value: confirmationAppeared)
                    .symbolEffectsRemoved(reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("All set. Thank you.").font(.title2.weight(.semibold))
                    Text("Your photo is safely in the station’s records.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .accessibilityIdentifier("saveConfirmation")
            .accessibilityElement(children: .combine)
            .accessibilityFocused($statusFocused)
            .onAppear { confirmationAppeared = true }
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Leave the item with staff").font(.headline)
                    Text("They’ll help it get back to its owner.").font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title3).foregroundStyle(FoundStyle.accent)
            }
            .padding(.vertical, 6)
            if !item.note.isEmpty { Text(item.note).font(.subheadline).foregroundStyle(.secondary) }
        } footer: {
            Text("Finish clears this screen for the next visitor. Your saved report stays in the station’s records.")
        }
    }
}
