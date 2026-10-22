import SwiftUI

struct StationHomeView: View {
    let openStaff: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 800 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    welcome
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(spacing: 20))
                    layout {
                        taskButton(title: "I found something", detail: "Help an item find its way back.",
                                   action: "Register an item", tab: .report)
                        taskButton(title: "I lost something", detail: "Let’s find what you’re missing.",
                                   action: "Find an item", tab: .find)
                    }
                    LockerAvailabilityView()
                    if store.reportNeedsStaff {
                        Notice(text: "Registration needs staff assistance. You can still search for lost items.",
                               symbol: "person.crop.circle.badge.exclamationmark")
                            .accessibilityIdentifier("stationNeedsStaff")
                    }
                    if store.lockerNeedsStaff {
                        Notice(text: "A compartment request needs staff assistance. Please ask staff to check it before starting another storage or collection request.",
                               symbol: "person.crop.circle.badge.exclamationmark")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(FoundStyle.accent).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A shared station, a fresh start.").font(.subheadline.weight(.medium))
                            Text("Follow the compartment number on screen. Confirm after placing or collecting your item and closing the door.")
                                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .center).padding(.horizontal, 8)
                }
                .frame(maxWidth: 1060).padding(wide ? 36 : 24).frame(maxWidth: .infinity)
            }
        }
        .background(StationBackdrop())
        .navigationTitle("Found")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openStaff) {
                    HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("Staff") }
                }.accessibilityIdentifier("staffEntry")
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Self-service station", systemImage: "building.2")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                ConnectionBadge()
            }
            let brandLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
            brandLayout {
                Image("FoundBrandMark")
                    .renderingMode(.original).resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lost & Found").font(.largeTitle.bold()).tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Welcome. What can we help you with?")
                        .font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func taskButton(title: String, detail: String, action: String, tab: AppStore.Tab) -> some View {
        let tint = tab == .report ? FoundStyle.accent : FoundStyle.searchAccent
        return Button { _ = store.beginVisitorTask(tab) } label: {
            VStack(alignment: .leading, spacing: 16) {
                StationTaskArtwork(isReport: tab == .report).frame(height: 128)
                    .frame(maxWidth: .infinity).padding(.bottom, 6)
                Text(title).font(.title2.bold()).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(action).font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.body.weight(.semibold)).frame(width: 42, height: 42)
                        .background(tint.opacity(0.09), in: Circle())
                }.foregroundStyle(tint).padding(.top, 6)
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: [FoundStyle.surface, tint.opacity(0.055)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(tint.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 1))
            .shadow(color: tint.opacity(0.055), radius: 20, x: 0, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .buttonStyle(StationPressStyle())
        .disabled(store.isLockerBusy || (tab == .report && (store.reportNeedsStaff || store.lockerNeedsStaff ||
            (store.lockerStatus.map { !$0.enabled || !$0.compartments.contains { $0.state == "free" } } ?? true))))
        .accessibilityIdentifier(tab == .report ? "startReport" : "startFind")
    }
}

/// Symbol artwork explains the task without suggesting that these are saved items.
private struct StationTaskArtwork: View {
    let isReport: Bool
    private var tint: Color { isReport ? FoundStyle.accent : FoundStyle.searchAccent }

    var body: some View {
        ZStack {
            Ellipse().fill(tint.opacity(0.065)).frame(width: 230, height: 104).offset(y: 16)
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(FoundStyle.surface).frame(width: 154, height: 112)
                .overlay {
                    Image(systemName: isReport ? "camera.fill" : "magnifyingglass")
                        .font(.system(size: 52, weight: .medium)).foregroundStyle(tint.gradient)
                        .symbolRenderingMode(.hierarchical)
                }
                .overlay(RoundedRectangle(cornerRadius: 25).stroke(tint.opacity(0.12), lineWidth: 1))
                .rotationEffect(.degrees(isReport ? -7 : 6))
                .shadow(color: tint.opacity(0.12), radius: 12, x: 0, y: 8)
            Image(systemName: isReport ? "tag.fill" : "key.fill")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(tint)
                .frame(width: 54, height: 54).background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(tint.opacity(0.12), lineWidth: 1))
                .rotationEffect(.degrees(isReport ? 12 : -12)).offset(x: 87, y: 34)
                .shadow(color: tint.opacity(0.1), radius: 8, x: 0, y: 4)
            Image(systemName: isReport ? "plus" : "sparkle")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(tint.opacity(0.5)).offset(x: -105, y: -36)
        }.accessibilityHidden(true)
    }
}
