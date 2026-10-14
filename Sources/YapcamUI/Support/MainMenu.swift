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
        add("Recording", [
            item("Start Recording", #selector(AppDelegate.toggleRecording)),
            item("Pause Recording", #selector(AppDelegate.togglePause)),
            .separator(),
            item("Show Toolbar", #selector(AppDelegate.toggleToolbar)),
        ])
        add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
        ])
        NSApp.windowsMenu = main.items.last?.submenu
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
