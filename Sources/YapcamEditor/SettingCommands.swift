import SwiftUI
import YapcamCore

extension EditorModel {
    /// ⌘K can reach any editor setting: sections, aspect ratios, preview options, and the on/off and option settings of the inspector.
    /// Each command applies the same change the inspector control makes (same paths, same undo behaviour).
    var settingCommands: [PaletteCommand] {
        var out: [PaletteCommand] = []
        func add(_ title: String, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) { out.append(PaletteCommand(title: title, shortcut: "", enabled: enabled, run: run)) }

        for s in InspectorSection.allCases { add("Go to \(s.title)", enabled: s.isAvailable(in: self)) { [self] in showSection(s) } }
        for a in AspectPreset.allCases { add("Aspect ratio: \(a.label)", enabled: string("canvas.aspect", default: "source") != a.rawValue) { [self] in setAspect(a) } }

        // Preview.
        for h in PreviewOptions.heights { add("Preview size: \(h)p") { [self] in var o = previewOptions; o.maxHeight = h; setPreviewOptions(o) } }
        for r in PreviewOptions.resolutions { add("Preview resolution: \(r.label)") { [self] in var o = previewOptions; o.resolution = r.value; setPreviewOptions(o) } }
        for rate in PreviewOptions.rates { add("Playback speed: \(PreviewOptions.rateLabel(rate))") { [self] in var o = previewOptions; o.rate = rate; setPreviewOptions(o) } }

        // On/off settings: "Turn on/off <name>" shows the state it would change to.
        let toggles: [(String, String, Bool, Bool)] = [   // title, path, default, available
            ("cursor", "cursor.visible", true, hasMouseData),
            ("cursor shake removal", "cursor.remove_shakes", false, hasMouseData),
            ("cursor loop to start", "cursor.loop_to_start", false, hasMouseData),
            ("always use the default arrow", "cursor.always_default", false, hasMouseData),
            ("hide cursor when idle", "cursor.hide_when_idle", false, hasMouseData),
            ("camera", "camera.visible", true, hasCamera),
            ("typed keys overlay", "cursor.key_overlay.enabled", false, hasKeystrokes),
            ("inset border", "canvas.inset", false, true),
            ("window frame", "canvas.window_chrome", false, true),
            ("automatic zooms", "zoom_settings.automatic", true, true),
            ("follow cursor while zoomed", "zoom_settings.follow_cursor", true, true),
            ("start zoom animation early", "zoom_settings.start_early", false, true),
            ("click sounds", "audio.click_sound.enabled", false, true),
            ("microphone mute", "audio.mic_muted", false, hasMic),
            ("system audio mute", "audio.system_muted", false, true),
        ]
        for (name, path, def, available) in toggles {
            let on = path == "canvas.inset" ? number(path) > 0 : bool(path, default: def)
            add("\(on ? "Turn off" : "Turn on") \(name)", enabled: available) { [self] in
                if path == "canvas.inset" { setInsetEnabled(!on) } else { set(path, bool: !on) }
            }
        }
        add("Hide cursor", enabled: hasMouseData && bool("cursor.visible", default: true)) { [self] in set("cursor.visible", bool: false) }
        add("Show cursor", enabled: hasMouseData && !bool("cursor.visible", default: true)) { [self] in set("cursor.visible", bool: true) }

        // Option settings.
        for t in ["wallpaper", "gradient", "solid", "blurred_screen"] {
            let name = ["wallpaper": "Wallpaper", "gradient": "Gradient", "solid": "Color", "blurred_screen": "Blur"][t]!
            add("Background: \(name)", enabled: t != "wallpaper") { [self] in set("canvas.background.kind", string: t == "wallpaper" ? "gradient" : t) }
        }
        add("Shadow: Classic", enabled: hasShadowStyle) { [self] in set("canvas.shadow.style", string: "classic") }
        add("Shadow: Directional", enabled: hasShadowStyle) { [self] in set("canvas.shadow.style", string: "directional") }
        for (label, v) in [("Overlay", "overlay"), ("Cutout", "cutout"), ("Split", "split")] {
            add("Camera layout: \(label)", enabled: hasCamera) { [self] in set("camera.layout_settings.mode", string: v) }
        }
        for (label, v) in [("None", "none"), ("Circle", "ring"), ("Ripple", "highlight")] {
            add("Click effect: \(label)", enabled: hasMouseData) { [self] in set("cursor.click_effect", string: v) }
        }
        for (label, v) in [("Dark", false), ("Light", true)] {
            add("Caption colour: \(label)", enabled: hasMic) { [self] in var l = captionLook; l.light = v; setCaptionLook(l) }
        }
        add("Randomize wallpaper") { [self] in applyRandomWallpaper() }
        add("Randomize gradient") { [self] in randomizeGradient() }
        add("Remove filler words", enabled: fillerWordCount > 0) { [self] in removeFillerWords() }
        add("Tighten pauses", enabled: !pauseCuts().isEmpty) { [self] in tightenPauses() }
        add("Export transcript as SRT…", enabled: !transcriptWords.isEmpty) { [self] in chooseTranscriptExport(.srt, suggestedName: "Transcript") }
        return out
    }
}
