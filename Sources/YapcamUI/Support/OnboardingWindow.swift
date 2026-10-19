import AppKit
import SwiftUI
import YapcamDesign

/// Pure onboarding rules, unit-tested.
enum OnboardingFlow {
    /// First run: what recording needs plus the devices people expect to see working. A ready page closes it.
    static let firstRun: [AppPermission] = [.screen, .microphone, .camera, .accessibility]
    /// The ready page lists these with a live check.
    static let readyChecks: [AppPermission] = [.screen, .microphone, .camera]

    /// Where the screen page stands. macOS applies a new screen grant only to a fresh process, and a grant
    /// left by another copy with the same bundle ID shows as on in System Settings but never reaches this one.
    enum ScreenStage: Equatable { case ask, switchOn, notSeenAfterRestart, granted }
    static func screenStage(granted: Bool, requested: Bool, restartedSinceRequest: Bool) -> ScreenStage {
        if granted { return .granted }
        if !requested { return .ask }
        return restartedSinceRequest ? .notSeenAfterRestart : .switchOn
    }

    /// "All set" only when screen, microphone and camera all really work.
    static func allSet(_ granted: (AppPermission) -> Bool) -> Bool { readyChecks.allSatisfy(granted) }
}

@MainActor final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private let model = OnboardingModel()

    final class OnboardingModel: ObservableObject {
        @Published var reason: String?
        @Published var showAll = false
        /// Which page is showing (one past the permissions is the ready page), and whether its "not detected?" page is open.
        @Published var step = 0
        @Published var help = false
    }

    /// `all: false` is the first run (ends on the ready page); the full list is for review.
    func show(reason: String?, all: Bool = false) {
        model.reason = reason
        model.showAll = all
        model.step = PermissionsModel.shared.takeResumeStep() ?? 0
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
            w.delegate = self
            window = w
        }
        // The floating toolbar would cover the onboarding; it comes back when the onboarding closes.
        ToolbarPanelController.shared.hide()
        PermissionsModel.shared.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        AppSettings.shared.hasCompletedOnboarding = true
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
    func front() { NSApp.activate(); window?.makeKeyAndOrderFront(nil) }

    /// Closed with the window button: bring the toolbar back if Yapcam can record.
    func windowWillClose(_ notification: Notification) {
        if PermissionsModel.shared.state(.screen) == .granted { ToolbarPanelController.shared.show() }
    }
}

/// One permission per page: what it is, one line why, one button, and a clear "Connected" once it works.
/// The first run ends on a ready page that checks screen, microphone and camera live.
struct OnboardingView: View {
    static let size = CGSize(width: 460, height: 420)
    @ObservedObject var model: OnboardingWindow.OnboardingModel
    var close: () -> Void
    @EnvironmentObject var perms: PermissionsModel
    /// Permissions can change in System Settings at any time; look again while we show.
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private var shown: [AppPermission] { model.showAll ? AppPermission.allCases : OnboardingFlow.firstRun }
    /// The review list (`showAll`) has no ready page.
    private var pageCount: Int { shown.count + (model.showAll ? 0 : 1) }
    private var onReady: Bool { !model.showAll && model.step >= shown.count }
    private var current: AppPermission { shown[min(model.step, shown.count - 1)] }
    private var isLast: Bool { model.step >= pageCount - 1 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.help { TroubleshootPage(permission: current) } else if onReady { readyPage } else { page }
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

    private func header(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 18) {
            if pageCount > 1 { StepDots(count: pageCount, index: model.step) }
            Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(Yap.title)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Yap.platter))
                .padding(.top, 10)
            VStack(spacing: 6) {
                Text(title).font(Yap.Font.title(20)).foregroundStyle(Yap.title).multilineTextAlignment(.center)
                Text(text).font(Yap.Font.body).foregroundStyle(Yap.body)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var page: some View {
        let p = current
        return VStack(spacing: 18) {
            header(p.symbol, p.title, model.step == 0 && model.reason != nil ? model.reason! : p.reason)
            if perms.state(p) == .granted {
                Connected(title: p.title)
            } else if p == .screen {
                screenActions
            } else {
                let ask = perms.state(p) == .notDetermined || !perms.hasRequested(p)
                Button(ask ? "Allow" : "Open System Settings") { perms.act(p) }
                    .buttonStyle(CapsuleButtonStyle(.primary, height: 32))
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

    /// Screen access walks through its stages on the page itself: allow, switch on and restart, and if a restart
    /// did not help, reset the entry macOS kept for another copy of Yapcam.
    @ViewBuilder private var screenActions: some View {
        switch perms.screenStage {
        case .ask, .granted:
            Button("Allow") { perms.act(.screen) }
                .buttonStyle(CapsuleButtonStyle(.primary, height: 32))
                .accessibilityLabel("Allow screen recording")
        case .switchOn:
            Hint("Switch Yapcam on in System Settings, then restart Yapcam. This page opens again with a check.")
            HStack(spacing: 10) {
                Button("Open System Settings") { perms.open(.screen) }.buttonStyle(CapsuleButtonStyle(.secondary, height: 32))
                Button("Restart Yapcam") { restart() }.buttonStyle(CapsuleButtonStyle(.primary, height: 32))
            }
        case .notSeenAfterRestart:
            Hint("Still not detected. macOS probably kept the switch of an older Yapcam. Reset it, switch Yapcam on again, then restart.")
            HStack(spacing: 10) {
                Button("Restart Yapcam") { restart() }.buttonStyle(CapsuleButtonStyle(.secondary, height: 32))
                Button("Reset and ask again") { perms.reset(.screen); perms.request(.screen) }
                    .buttonStyle(CapsuleButtonStyle(.primary, height: 32))
            }
        }
    }

    private func restart() { perms.relaunch(resumeStep: model.step) }

    private var readyPage: some View {
        let ready = OnboardingFlow.allSet { perms.state($0) == .granted }
        return VStack(spacing: 18) {
            header(ready ? "checkmark.circle" : "checklist", ready ? "All set" : "Almost ready",
                   ready ? "Screen, microphone and camera work. You can record now."
                         : "Recording needs screen access. Microphone and camera are optional.")
            VStack(spacing: 0) {
                ForEach(Array(OnboardingFlow.readyChecks.enumerated()), id: \.element) { i, p in
                    if i > 0 { Hairline(axis: .horizontal).padding(.horizontal, 14) }
                    ReadyRow(permission: p, granted: perms.state(p) == .granted) { model.step = shown.firstIndex(of: p) ?? 0 }
                }
            }
            .background(RoundedRectangle(cornerRadius: Yap.Radius.card, style: .continuous).fill(Yap.platterHover))
        }
        .frame(maxWidth: .infinity)
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
                let waiting = !onReady && current.isRequired && perms.state(current) != .granted
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

private struct Connected: View {
    let title: String
    var body: some View {
        Label("Connected", systemImage: "checkmark.circle.fill").font(Yap.Font.label).foregroundStyle(Color.green)
            .frame(height: 32)
            .accessibilityLabel("\(title): connected")
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Yap.Font.caption).foregroundStyle(Yap.caption)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
}

/// One line on the ready page: a live check, or a button back to that permission's page.
private struct ReadyRow: View {
    let permission: AppPermission
    let granted: Bool
    let fix: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.symbol).frame(width: 20).foregroundStyle(Yap.label)
            Text(permission == .screen ? "Screen & system audio" : permission.title).font(Yap.Font.label).foregroundStyle(Yap.label)
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                    .accessibilityLabel("\(permission.title): connected")
            } else {
                Button("Set up", action: fix).buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
                    .accessibilityLabel("Set up \(permission.title)")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
