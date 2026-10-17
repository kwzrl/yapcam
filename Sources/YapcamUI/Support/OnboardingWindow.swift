import AppKit
import SwiftUI
import YapcamDesign

@MainActor final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private let model = OnboardingModel()

    final class OnboardingModel: ObservableObject {
        @Published var reason: String?
        @Published var showAll = false
        /// Which permission page is showing, and whether its "not detected?" page is open.
        @Published var step = 0
        @Published var help = false
    }

    /// `all: false` is the first-run list (Screen Recording and Accessibility); the full list is for review.
    func show(reason: String?, all: Bool = false) {
        model.reason = reason
        model.showAll = all
        model.step = 0
        model.help = false
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: OnboardingView.size.width, height: OnboardingView.size.height),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.applyYapChrome()
            w.title = "Welcome to Yapcam"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(model: model, close: { [weak self] in self?.close() })
                .environmentObject(PermissionsModel.shared))
            w.center()
            RecordingController.shared.engine.registerExcluded(w)
            window = w
        }
        PermissionsModel.shared.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        AppSettings.shared.hasCompletedOnboarding = true
        window?.orderOut(nil)
    }
}

/// One permission per page: what it is, one line why, one button. Everything about "it's on but Yapcam doesn't
/// see it" lives on its own page behind a link, not on the first screen.
struct OnboardingView: View {
    static let size = CGSize(width: 460, height: 420)
    @ObservedObject var model: OnboardingWindow.OnboardingModel
    var close: () -> Void
    @EnvironmentObject var perms: PermissionsModel
    /// Screen recording and accessibility can change in System Settings at any time; look again while we show.
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    /// First run asks only for what recording needs; the rest is asked for the first time it is used.
    private var shown: [AppPermission] { model.showAll ? AppPermission.allCases : [.screen, .accessibility] }
    private var current: AppPermission { shown[min(model.step, shown.count - 1)] }
    private var isLast: Bool { model.step >= shown.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.help { TroubleshootPage(permission: current) } else { page }
            }
            .transition(.opacity)
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Yap.ground)
        .yapWindow()
        .animation(.smooth(duration: 0.25), value: model.step)
        .animation(.smooth(duration: 0.25), value: model.help)
        .onReceive(tick) { _ in perms.refresh() }
    }

    private var page: some View {
        let p = current, state = perms.state(p)
        return VStack(spacing: 18) {
            if shown.count > 1 { StepDots(count: shown.count, index: model.step) }
            Image(systemName: p.symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(Yap.title)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Yap.platter))
                .padding(.top, 10)
            VStack(spacing: 6) {
                Text(p.title).font(Yap.Font.title(20)).foregroundStyle(Yap.title).multilineTextAlignment(.center)
                Text(model.step == 0 && model.reason != nil ? model.reason! : p.reason)
                    .font(Yap.Font.body).foregroundStyle(Yap.body)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if state == .granted {
                Label("Granted", systemImage: "checkmark.circle.fill").font(Yap.Font.label).foregroundStyle(Color.green)
                    .frame(height: 32)
                    .accessibilityLabel("\(p.title): granted")
            } else {
                let ask = state == .notDetermined || !perms.hasRequested(p)
                Button(ask ? "Allow" : "Open System Settings") { perms.act(p) }
                    .buttonStyle(CapsuleButtonStyle(p.isRequired ? .primary : .secondary, height: 32))
                    .accessibilityLabel("\(ask ? "Allow" : "Open System Settings") for \(p.title)")
                if !ask {
                    Button("Turned on, but not detected?") { model.help = true }
                        .buttonStyle(.plain).font(Yap.Font.caption).foregroundStyle(Yap.caption)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .id(p)
    }

    private var footer: some View {
        HStack {
            if model.help || model.step > 0 {
                Button("Back") { if model.help { model.help = false } else { model.step -= 1 } }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 32))
            }
            Spacer()
            if !model.help {
                // While a required permission is missing, the page's own button is the primary one.
                let waiting = current.isRequired && perms.state(current) != .granted
                Button(primaryTitle, action: primary)
                    .buttonStyle(CapsuleButtonStyle(waiting ? .secondary : .primary, height: 32))
                    .keyboardShortcut(waiting ? nil : .defaultAction)
            }
        }
    }

    private var primaryTitle: String {
        if !isLast { return perms.state(current) == .granted || !current.isRequired ? "Continue" : "Skip for now" }
        if perms.state(.screen) == .granted { return model.showAll ? "Done" : "Start recording" }
        return "Continue without screen access"
    }

    private func primary() {
        if !isLast { model.step += 1; return }
        close()
        if perms.state(.screen) == .granted, !model.showAll { ToolbarPanelController.shared.show() }
    }
}

private struct StepDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == index ? Yap.title : Yap.faint).frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement().accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

/// The fixes for a permission that is switched on in System Settings but not seen by this build, in the
/// order that usually works.
private struct TroubleshootPage: View {
    let permission: AppPermission
    @EnvironmentObject var perms: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Turned on, but not detected?").font(Yap.Font.title(18)).foregroundStyle(Yap.title)
                Text("macOS sometimes keeps an old entry. Try these in order.")
                    .font(Yap.Font.body).foregroundStyle(Yap.body)
            }
            VStack(spacing: 0) {
                FixRow(number: 1, title: "Restart Yapcam", detail: "Screen access only applies after a restart.", action: "Restart") {
                    perms.relaunch()
                }
                Hairline(axis: .horizontal).padding(.horizontal, 14)
                FixRow(number: 2, title: "Reset the entry", detail: "Removes Yapcam from the list, then macOS asks again.", action: "Reset") {
                    perms.reset(permission); perms.request(permission)
                }
                Hairline(axis: .horizontal).padding(.horizontal, 14)
                FixRow(number: 3, title: "Check System Settings", detail: "Yapcam has to be switched on under Privacy & Security.", action: "Open") {
                    perms.open(permission)
                }
            }
            .background(RoundedRectangle(cornerRadius: Yap.Radius.card, style: .continuous).fill(Yap.platterHover))
        }
    }
}

private struct FixRow: View {
    let number: Int
    let title: String
    let detail: String
    let action: String
    let run: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(Yap.Font.technical).foregroundStyle(Yap.technical).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Yap.Font.label).foregroundStyle(Yap.label)
                Text(detail).font(Yap.Font.caption).foregroundStyle(Yap.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: run).buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
