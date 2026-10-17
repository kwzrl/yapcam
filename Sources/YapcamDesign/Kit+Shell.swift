import AppKit
import SwiftUI

// Kit parts of the editor shell (title row, stage controls): a slot that opens a menu, and the docked hairline.

/// A compact slot (icon only, label in the tooltip) that opens a menu; looks and moves like `SlotButton`.
public struct SlotMenu<Items: View>: View {
    let symbol: String
    let label: String
    var help: String
    var size: CGFloat
    let items: Items
    @State private var hover = false

    public init(symbol: String, label: String, help: String = "", size: CGFloat = Yap.Grid.cell, @ViewBuilder items: () -> Items) {
        self.symbol = symbol; self.label = label; self.help = help; self.size = size; self.items = items()
    }

    public var body: some View {
        Menu { items } label: {
            Image(systemName: symbol).font(.system(size: size * 0.4, weight: .regular))
                .frame(width: size, height: size)
        }
        .menuStyle(.button)
        .buttonStyle(PressStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(hover ? Yap.title : Yap.label)
        .background(Platter(active: false, hover: hover, radius: Yap.concentric(size / 2 + 6, inset: 6)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label)
    }
}

/// A quiet text menu on the stage ("16:9", "Full"): caption grey, brightens on hover, value in yellow when given.
public struct QuietMenu<Items: View>: View {
    let symbol: String?
    let title: String
    var help: String
    let items: Items
    @State private var hover = false

    public init(symbol: String? = nil, title: String, help: String = "", @ViewBuilder items: () -> Items) {
        self.symbol = symbol; self.title = title; self.help = help; self.items = items()
    }

    public var body: some View {
        Menu { items } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(title).font(Yap.Font.caption).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(PressStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(hover ? Yap.title : Yap.caption)
        .background(Platter(active: false, hover: hover, radius: 14))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(help.isEmpty ? title : help)
    }
}

/// The hairline between docked surfaces of an opaque window (`Yap.dockHairline`).
public struct DockSeparator: View {
    var axis: Axis
    public init(axis: Axis = .vertical) { self.axis = axis }
    public var body: some View { Hairline(axis: axis, opacity: Yap.dockHairline).accessibilityHidden(true) }
}
