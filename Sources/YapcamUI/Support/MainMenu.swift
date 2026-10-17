import AppKit

@MainActor enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let s = AppSettings.shared

        func item(_ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = .command, target t: AnyObject? = target) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = t
            return i
        }
        /// A menu item whose key equivalent follows the user's shortcut for `action`.
        func shortcutItem(_ title: String, _ sel: Selector, _ action: HotkeyAction) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            if let k = s.combo(for: action)?.menuKey { i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.flags }
            i.target = target
            return i
        }
        func afterRecordingItem() -> NSMenuItem {
            let host = NSMenuItem(title: "After Recording", action: nil, keyEquivalent: "")
            let m = AfterRecordingMenu.populated(); m.delegate = AfterRecordingMenu.mainMenuDelegate
            host.submenu = m
            return host
        }
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }

        add("Yapcam", [
            item("About Yapcam", #selector(AppDelegate.showAbout)),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings), ","),
            item("Permissions…", #selector(AppDelegate.showPermissions)),
            item("Export Diagnostics…", #selector(AppDelegate.exportDiagnostics)),
            .separator(),
            item("Hide Yapcam", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", mods: [.command, .option], target: NSApp),
            .separator(),
            item("Quit Yapcam", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        add("File", [
            item("Open Recording…", #selector(AppDelegate.openProject), "o"),
            item("Import Video…", #selector(AppDelegate.importVideo), "i"),
            item("Recordings…", #selector(AppDelegate.showRecordings), "r", mods: [.command, .shift]),
            item("Show Recordings Folder", #selector(AppDelegate.showStorageFolder)),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil),
        ])
        add("Edit", [
            item("Undo", #selector(AppDelegate.editUndo), "z"),
            item("Redo", #selector(AppDelegate.editRedo), "z", mods: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil),
            item("Copy", #selector(NSText.copy(_:)), "c", target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil),
            .separator(),
            item("Split at Playhead", #selector(AppDelegate.editSplit), "b"),
            item("Add Zoom at Playhead", #selector(AppDelegate.editAddZoom), "z", mods: [.command, .option]),
            item("Command Palette…", #selector(AppDelegate.editPalette), "k"),
        ])
        let presets = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presets.submenu = PresetsMenuController.shared.menu
        main.addItem(presets)
        add("Recording", [
            item("Start Recording", #selector(AppDelegate.toggleRecording)),
            item("Pause Recording", #selector(AppDelegate.togglePause)),
            .separator(),
            item("Add Marker", #selector(AppDelegate.addMarker)),
            item("Restart Recording…", #selector(AppDelegate.restartRecording)),
            item("Cancel Recording…", #selector(AppDelegate.cancelRecording)),
            .separator(),
            afterRecordingItem(),
            shortcutItem("Speaker Notes…", #selector(AppDelegate.showNotes), .toggleNotes),
            item("Show Toolbar", #selector(AppDelegate.toggleToolbar)),
            .separator(),
            shortcutItem("Open Last Recording", #selector(AppDelegate.openLastRecording), .openLast),
            shortcutItem("Quick Export: Copy to Clipboard", #selector(AppDelegate.quickExportCopy), .quickExportCopy),
            shortcutItem("Quick Export: Save to File…", #selector(AppDelegate.quickExportSave), .quickExportSave),
        ])
        add("Help", [
            item("Third-Party Notices", #selector(AppDelegate.showThirdPartyNotices)),
        ])
        NSApp.helpMenu = main.items.last?.submenu
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
        ])
        NSApp.windowsMenu = main.items.first { $0.title == "Window" }?.submenu
        _ = s
        return main
    }

    static func statusMenu(target: AppDelegate) -> NSMenu {
        let m = NSMenu()
        for (title, sel) in [("Start Recording", #selector(AppDelegate.toggleRecording)),
                             ("Pause Recording", #selector(AppDelegate.togglePause)),
                             ("Show Toolbar", #selector(AppDelegate.toggleToolbar))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = target; m.addItem(i)
        }
        m.addItem(.separator())
        for (title, sel) in [("Recordings…", #selector(AppDelegate.showRecordings)),
                             ("Open Recording…", #selector(AppDelegate.openProject)),
                             ("Settings…", #selector(AppDelegate.showSettings))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = target; m.addItem(i)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Yapcam", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }
}

@MainActor enum AboutWindow {
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Local screen recorder and editor.\nNo account, no cloud, no watermark.\nApache License 2.0."),
        ])
    }
}
