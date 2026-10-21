import SwiftUI

enum FoundStyle {
    static let accent = Color("AccentColor")
    static let buttonBackground = Color(red: 0.192, green: 0.361, blue: 0.282)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let soft = accent.opacity(0.09)
    static let searchAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.60, green: 0.74, blue: 0.88, alpha: 1)
            : UIColor(red: 0.25, green: 0.39, blue: 0.53, alpha: 1)
    })
}

struct StationBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        LinearGradient(colors: [FoundStyle.background, FoundStyle.accent.opacity(colorScheme == .dark ? 0.055 : 0.045), FoundStyle.background],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(FoundStyle.background).ignoresSafeArea()
    }
}

struct StationPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.88 : 1))
            .animation(reduceMotion ? nil : .smooth(duration: configuration.isPressed ? 0.12 : 0.25), value: configuration.isPressed)
    }
}

private struct StationEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    func body(content: Content) -> some View {
        content.opacity(appeared ? 1 : 0.72)
            // Restore readability before the small positional movement settles.
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.16), value: appeared)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: appeared)
            .task {
                guard !appeared else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                appeared = true
            }
    }
}

private struct StationFloatingControl: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(FoundStyle.surface, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.15), lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

private struct StationCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.primary.opacity(contrast == .increased ? 0.25 : 0.055), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 14, x: 0, y: 5)
    }
}

struct Page<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geometry in
            let wide = sizeClass == .regular && geometry.size.width >= 820 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { content }
                    .frame(maxWidth: wide ? 1180 : 720)
                    .padding(wide ? 28 : 20).frame(maxWidth: .infinity)
                    .environment(\.widePageLayout, wide)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(StationBackdrop())
    }
}

private struct WidePageLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var widePageLayout: Bool {
        get { self[WidePageLayoutKey.self] }
        set { self[WidePageLayoutKey.self] = newValue }
    }
}

/// Changes arrangement without recreating the controls or their local state.
struct AdaptiveColumns<Leading: View, Trailing: View>: View {
    @Environment(\.widePageLayout) private var wide
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            leading.frame(maxWidth: .infinity, alignment: .topLeading)
            trailing.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct IconBadge: View {
    let symbol: String
    var tint: Color = FoundStyle.accent
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}

struct CardHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Environment(\.widePageLayout) private var wide

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.largeTitle.weight(.bold)).tracking(-0.7)
                Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if wide { IconBadge(symbol: symbol, size: 76) }
        }
    }
}

extension View {
    func foundCard() -> some View {
        modifier(StationCard())
    }
    func stationEntrance() -> some View { modifier(StationEntrance()) }
    func stationFloatingControl() -> some View { modifier(StationFloatingControl()) }
}

struct ConnectionBadge: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(store.connected ? FoundStyle.accent : Color.secondary).frame(width: 7, height: 7)
            Text(store.connected ? "Connected" : (store.isRefreshing ? "Connecting…" : "Offline"))
        }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

struct Notice: View {
    let text: String
    var symbol = "info.circle"
    var isError = false
    var body: some View {
        Label { Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true) }
            icon: { Image(systemName: symbol) }
            .foregroundStyle(isError ? Color.red : .secondary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(isError ? Color.red.opacity(0.06) : FoundStyle.soft, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }
}

struct PrimaryAction: View {
    let title: String
    let symbol: String
    var busy = false
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Group {
            if #available(iOS 26.0, *), !reduceTransparency {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large).buttonBorderShape(.capsule)
        .tint(FoundStyle.buttonBackground)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().tint(isEnabled ? .white : .secondary) } else { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .foregroundStyle(isEnabled ? Color.white : Color.secondary).frame(maxWidth: .infinity, minHeight: 28).padding(.vertical, 5)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: busy)
        }
    }
}

struct ItemPhoto: View {
    let item: FoundItem
    let api: APIClient
    var height: CGFloat = 180
    var fit = false
    var body: some View {
        AsyncImage(url: api.imageURL(for: item)) { phase in
            switch phase {
            case .success(let image):
                if fit { image.resizable().scaledToFit() }
                else { image.resizable().scaledToFill() }
            case .failure:
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text("Photo unavailable").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height).frame(maxWidth: .infinity).background(FoundStyle.soft)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityLabel("Photo of \(item.title)")
    }
}

/// Shared by category names and the first recognition tag. The text carries
/// accessibility meaning; the symbol is a visual aid, not another spoken label.
struct ItemCategoryLabel: View {
    let title: String
    let primaryTag: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ItemCategorySymbol(primaryTag: primaryTag)
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct ItemCategorySymbol: View {
    let primaryTag: String?

    var body: some View {
        let symbol = ItemCategory.matching(primaryTag).symbolName
        Image(systemName: UIImage(systemName: symbol) == nil ? "shippingbox" : symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(FoundStyle.accent)
            .accessibilityHidden(true)
    }
}

struct TagList: View {
    let tags: [String]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ForEach(tags.indices, id: \.self) { tag(at: $0) } }
            VStack(alignment: .leading, spacing: 8) { ForEach(tags.indices, id: \.self) { tag(at: $0) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
    }
    private func tag(at index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if index == 0 { ItemCategorySymbol(primaryTag: tags[index]) }
            Text(tags[index])
        }
            .font(.caption.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(FoundStyle.accent).background(FoundStyle.soft, in: Capsule())
    }
}

struct ItemSummary: View {
    let item: FoundItem
    var transitionNamespace: Namespace.ID? = nil
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemPhoto(item: item, api: store.client)
                .modifier(ItemPhotoTransitionSource(id: item.id, namespace: transitionNamespace))
            ItemCategoryLabel(title: item.title, primaryTag: item.recognition?.tags.first)
                .font(.headline).foregroundStyle(.primary)
            Label(item.dateLabel, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            if let tags = item.recognition?.tags, !tags.isEmpty { TagList(tags: tags) }
            else {
                Label(item.isPending ? "Tagging in progress" : "Photo saved", systemImage: item.isPending ? "sparkles" : "checkmark.circle")
                    .font(.caption).foregroundStyle(FoundStyle.accent)
            }
        }.foundCard()
    }
}

private struct ItemPhotoTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else { content }
    }
}

struct ItemDetailTransition: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else { content }
    }
}
