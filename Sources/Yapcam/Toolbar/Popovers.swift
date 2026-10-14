import SwiftUI

struct PopoverHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).padding(.bottom, 2)
    }
}

struct SourcePopover: View {
    @EnvironmentObject var settings: AppSettings
    @State private var displays = Displays.all()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverHeader(title: "Record")
            VStack(spacing: 2) {
                ForEach(displays) { d in
                    Button {
                        settings.sourceMode = .display
                        settings.displayID = d.id
                    } label: {
                        HStack {
                            Image(systemName: "display").frame(width: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(d.name)
                                Text("\(Int(d.pixelSize.width)) × \(Int(d.pixelSize.height))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isSelected(d) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { displays = Displays.all() }
    }

    private func isSelected(_ d: DisplayInfo) -> Bool {
        settings.sourceMode == .display && Displays.resolve(settings.displayID)?.id == d.id
    }
}

struct SystemAudioPopover: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "System audio")
            Toggle("Record system audio", isOn: $settings.systemAudio)
            Text("Sound played by apps and the system, without Yapcam's own sounds. Saved as its own track so you can mix it in the editor.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260)
    }
}
