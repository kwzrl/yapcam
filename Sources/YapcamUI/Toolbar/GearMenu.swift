import AppKit

/// The picker's gear menu: While recording / After recording / Countdown / Advanced, then app items.
@MainActor enum GearMenu {
    static let countdownChoices: [(String, Int)] = [("None", 0), ("3 Seconds", 3), ("5 Seconds", 5), ("10 Seconds", 10)]

    static func build(settings s: AppSettings) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, key: KeyCombo? = nil, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            if let k = key?.menuKey { item.keyEquivalent = k.key; item.keyEquivalentModifierMask = k.flags }
            menu.addItem(item)
        }
        func check(_ title: String, _ on: Bool, key: KeyCombo? = nil, _ toggle: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: toggle)
            item.state = on ? .on : .off
            if let k = key?.menuKey { item.keyEquivalent = k.key; item.keyEquivalentModifierMask = k.flags }
            menu.addItem(item)
        }
        func header(_ title: String) { let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false; menu.addItem(h) }

        header("While Recording")
        check("Hide Desktop Icons", s.hideDesktopIcons) { s.hideDesktopIcons.toggle() }
        check("Hide Dock Icon", s.hideDockWhileRecording) { s.hideDockWhileRecording.toggle() }
        check("Highlight Recorded Area", s.highlightRecordedArea) { s.highlightRecordedArea.toggle() }
        check("Show Speaker Notes", NotesWindow.shared.isVisible, key: s.combo(for: .toggleNotes)) { NotesWindow.shared.toggle() }
        menu.addItem(.separator())
        header("After Recording")
        check("Open Quick Export Widget", s.showQuickExportWidget) { s.showQuickExportWidget.toggle() }
        let after = NSMenuItem(title: "After Recording Action", action: nil, keyEquivalent: ""); after.submenu = AfterRecordingMenu.populated()
        menu.addItem(after)
        menu.addItem(.separator())

        let countdown = NSMenu()
        for (label, n) in countdownChoices {
            let item = ClosureMenuItem(title: label) { s.countdown = n }
            item.state = s.countdown == n ? .on : .off
            countdown.addItem(item)
        }
        let cd = NSMenuItem(title: "Recording Countdown", action: nil, keyEquivalent: ""); cd.submenu = countdown; menu.addItem(cd)

        // Advanced → Recording Engine: Yapcam has the one (ScreenCaptureKit) engine, so the only row is the fact.
        let engine = NSMenu()
        let only = NSMenuItem(title: "ScreenCaptureKit (the only engine)", action: nil, keyEquivalent: ""); only.state = .on; only.isEnabled = false
        engine.addItem(only)
        let engineItem = NSMenuItem(title: "Recording Engine", action: nil, keyEquivalent: ""); engineItem.submenu = engine
        let advanced = NSMenu(); advanced.addItem(engineItem)
        let adv = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: ""); adv.submenu = advanced; menu.addItem(adv)

        menu.addItem(.separator())
        add("Settings…", key: KeyCombo(keyCode: 43, modifiers: UInt32(256))) { SettingsWindow.shared.show() }     // ⌘,
        add("Projects…") { RecentProjectsWindow.shared.show() }
        add("Permissions…") { OnboardingWindow.shared.show(reason: nil, all: true) }
        menu.addItem(.separator())
        add("Hide Toolbar") { ToolbarPanelController.shared.hide() }
        add("Quit Yapcam") { NSApp.terminate(nil) }
        return menu
    }
}

/// "After recording": the three actions with a check on the current one.
@MainActor final class AfterRecordingMenu: NSObject, NSMenuDelegate {
    /// A fresh, filled menu (an NSMenu can hang under one parent only, so every parent gets its own).
    static func populated() -> NSMenu { let m = NSMenu(title: "After Recording"); fill(m); return m }
    static func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = AppSettings.shared
        for a in AfterRecording.allCases {
            let item = ClosureMenuItem(title: a.title) { s.afterRecording = a }
            item.state = s.afterRecording == a ? .on : .off
            menu.addItem(item)
        }
    }

    /// Kept alive for the main menu: refreshes the checks each time the menu opens.
    static let mainMenuDelegate = AfterRecordingMenu()
    func menuNeedsUpdate(_ menu: NSMenu) { Self.fill(menu) }
}
