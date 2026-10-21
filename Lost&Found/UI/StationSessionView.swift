import SwiftUI
import UIKit

private struct StaffToolsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var staffToolsEnabled: Bool {
        get { self[StaffToolsKey.self] }
        set { self[StaffToolsKey.self] = newValue }
    }
}

struct EndVisitButton: View {
    @Environment(AppStore.self) private var store
    @State private var confirming = false
    var body: some View {
        Button {
            if store.photoData != nil && !store.reportNeedsStaff { confirming = true }
            else { _ = store.endVisitorSession() }
        } label: {
            HStack(spacing: 6) { Image(systemName: "house"); Text("Finish") }
        }
        .disabled(store.isSaving)
        .accessibilityIdentifier("finishVisit")
        .confirmationDialog("Finish and return to the start?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Finish Visit", role: .destructive) { _ = store.endVisitorSession() }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(store.submission == nil
                 ? "Your unsaved photo and note will be cleared from this shared screen."
                 : "Your report needs checking. It will be kept for staff to retry safely and hidden from the next visitor.")
        }
    }
}

struct VisitorNavigation: ViewModifier {
    @Environment(AppStore.self) private var store
    func body(content: Content) -> some View {
        content.toolbar {
            if store.selectedTab != .home && store.selectedTab != .settings {
                ToolbarItem(placement: .topBarTrailing) { EndVisitButton() }
            }
        }
    }
}

/// Repeated on presented surfaces so the warning is also visible over a sheet/camera.
struct VisitorSessionOverlay: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        content.overlay {
            if let seconds = store.idleSecondsRemaining {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 18) {
                        ViewThatFits(in: .vertical) {
                            warningMessage(seconds: seconds)
                                .fixedSize(horizontal: false, vertical: true)
                            ScrollView { warningMessage(seconds: seconds) }
                                .scrollBounceBehavior(.basedOnSize)
                        }
                        VStack(spacing: 18) {
                            PrimaryAction(title: "Keep Working", symbol: "hand.tap") { store.recordVisitorActivity() }
                                .accessibilityIdentifier("keepVisit")
                            Button("Finish Now") { _ = store.endVisitorSession() }
                                .frame(minHeight: 44)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center).padding(28)
                    .frame(maxWidth: 460)
                    .background(FoundStyle.surface, in: RoundedRectangle(cornerRadius: 30))
                    .shadow(color: .black.opacity(0.12), radius: 30, x: 0, y: 12).padding(24)
                    .accessibilityAddTraits(.isModal)
                }.accessibilityIdentifier("visitorTimeout")
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), value: store.idleSecondsRemaining != nil)
    }

    private func warningMessage(seconds: Int) -> some View {
        VStack(spacing: 18) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "hand.tap").font(.largeTitle).foregroundStyle(FoundStyle.accent)
                    .frame(width: 72, height: 72).background(FoundStyle.soft, in: Circle()).accessibilityHidden(true)
            }
            Text("Still using this station?").font(.title2.bold())
            Text("Returning to the start in \(seconds) seconds.")
                .font(.body).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: seconds)
        }
    }
}

/// Observes touch activity without consuming or cancelling control/scroll gestures.
struct StationActivityMonitor: UIViewRepresentable {
    let activity: () -> Void
    func makeUIView(context: Context) -> ActivityView { ActivityView(activity: activity) }
    func updateUIView(_ view: ActivityView, context: Context) { view.activity = activity }

    final class ActivityView: UIView {
        var activity: () -> Void
        private weak var observedWindow: UIWindow?
        private var observer: TouchObserver?
        init(activity: @escaping () -> Void) {
            self.activity = activity
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let observer { observedWindow?.removeGestureRecognizer(observer) }
            observer = nil
            observedWindow = window
            guard let window else { return }
            let observer = TouchObserver { [weak self] in self?.activity() }
            window.addGestureRecognizer(observer)
            self.observer = observer
        }
        deinit { if let observer { observedWindow?.removeGestureRecognizer(observer) } }
    }

    final class TouchObserver: UIGestureRecognizer {
        let activity: () -> Void
        init(activity: @escaping () -> Void) {
            self.activity = activity
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            activity()
            state = .failed
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
