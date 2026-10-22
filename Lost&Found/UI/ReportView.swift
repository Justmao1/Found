import SwiftUI

struct ReportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.staffToolsEnabled) private var staffToolsEnabled
    @State private var photoSource: ReportPhotoSource?
    @State private var importing = false
    @State private var reportDraft: ReportDraftPresentation?

    var body: some View {
        let serverRevision = store.revision
        let visitorRevision = store.visitorRevision
        Page {
            AdaptiveColumns {
                ReportCaptureIllustration()
            } trailing: {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Photograph the item")
                            .font(.largeTitle.weight(.semibold)).tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Photograph the item and review it. Once identified, the station will assign an available compartment.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        captureTip("viewfinder", title: "Keep the whole item in view", detail: "Include any distinctive details.")
                        captureTip("sun.max", title: "Find a little light", detail: "A clear photo makes it easier to recognize.")
                    }
                    VStack(spacing: 12) {
                        if importing {
                            ProgressView("Preparing photo…")
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .accessibilityIdentifier("photoImportProgress")
                        } else if store.photoData != nil {
                            PrimaryAction(title: "Review Report", symbol: "square.and.pencil") { openEditor() }
                        } else {
                            PrimaryAction(title: "Take Photo", symbol: "camera.fill") { photoSource = .camera }
                                .disabled(photoSource != nil).accessibilityIdentifier("takePhoto")
                            if staffToolsEnabled {
                                Button { photoSource = .library } label: {
                                    Label("Choose Station Photo", systemImage: "photo.on.rectangle")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.bordered).controlSize(.large).disabled(photoSource != nil)
                                .accessibilityIdentifier("choosePhoto")
                            }
                        }
                    }
                    Label {
                        Text("Place the item in the numbered compartment, close its door, then confirm on this iPad.")
                    } icon: {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .foregroundStyle(FoundStyle.accent)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 20)
            }
        }
        .modifier(VisitorNavigation())
        .navigationTitle("Register a found item").navigationBarTitleDisplayMode(.inline)
        .modifier(ReportPhotoAcquisition(source: $photoSource, importing: $importing) { photo in
            guard store.acceptPhoto(photo, visitorRevision: visitorRevision, serverRevision: serverRevision) else { return }
            openEditor()
        })
        .sheet(item: $reportDraft) { draft in
            ReportEditorView(photo: draft.photo)
                .presentationDetents([.large]).presentationDragIndicator(.hidden)
        }
        .onAppear { if store.photoData != nil { openEditor() } }
    }

    private func captureTip(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func openEditor() {
        guard let photo = store.photoData, !store.reportNeedsStaff else { return }
        reportDraft = ReportDraftPresentation(photo: photo)
    }
}

private struct ReportCaptureIllustration: View {
    @Environment(\.widePageLayout) private var wide
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 38)
                    .fill(FoundStyle.accent.opacity(colorScheme == .dark ? 0.15 : 0.07))
                    .frame(width: 216, height: 216)
                    .rotationEffect(.degrees(-7))
                RoundedRectangle(cornerRadius: 32)
                    .fill(FoundStyle.surface)
                    .frame(width: 184, height: 184)
                    .shadow(color: .black.opacity(0.06), radius: 20, x: 0, y: 12)
                Image(systemName: "backpack.fill")
                    .font(.system(size: 88, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FoundStyle.accent)
                Image(systemName: "viewfinder")
                    .font(.system(size: 244, weight: .ultraLight))
                    .foregroundStyle(FoundStyle.accent.opacity(0.55))
                Image(systemName: "camera.fill")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(FoundStyle.accent)
                    .frame(width: 58, height: 58)
                    .background(FoundStyle.surface, in: Circle())
                    .overlay(Circle().strokeBorder(FoundStyle.accent.opacity(0.12)))
                    .offset(x: 100, y: 100)
            }
            .frame(height: 272)
            Text("Keep the whole item in view")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, wide ? 52 : 24)
        .background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(FoundStyle.accent.opacity(0.08)))
        .accessibilityHidden(true)
    }
}

private struct ReportDraftPresentation: Identifiable {
    let id = UUID()
    let photo: Data
}
