import AppKit
import SwiftUI

@MainActor final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private let model = OnboardingModel()

    final class OnboardingModel: ObservableObject { @Published var reason: String? }

    func show(reason: String?) {
        model.reason = reason
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 480),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
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

struct OnboardingView: View {
    @ObservedObject var model: OnboardingWindow.OnboardingModel
    var close: () -> Void
    @EnvironmentObject var perms: PermissionsModel
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions").font(.title2.weight(.semibold))
                Text(model.reason ?? "Yapcam records locally and never uploads anything. macOS asks you to grant each of these once.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(AppPermission.allCases) { p in
                    PermissionRow(permission: p)
                    if p != AppPermission.allCases.last { Divider() }
                }
            }
            .background(Color.primary.opacity(contrast.subtleFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("After changing a permission in System Settings, macOS may ask you to quit and reopen Yapcam. Screen recording changes only apply after a restart.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Check again") { perms.refresh() }
                Spacer()
                Button(perms.state(.screen) == .granted ? "Done" : "Continue without screen access") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PermissionRow: View {
    let permission: AppPermission
    @EnvironmentObject var perms: PermissionsModel

    var body: some View {
        let state = perms.state(permission)
        HStack(spacing: 12) {
            Image(systemName: permission.symbol).frame(width: 24).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.system(size: 13, weight: .medium))
                    if permission.isRequired { Text("Required").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(permission.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state == .granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(permission.title): granted")
            } else {
                Button(state == .notDetermined || !perms.hasRequested(permission) ? "Allow" : "Open Settings") {
                    perms.act(permission)
                }
                .accessibilityLabel("\(state == .notDetermined || !perms.hasRequested(permission) ? "Allow" : "Open Settings") for \(permission.title)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
