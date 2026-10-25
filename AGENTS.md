# Agent Notes — Yapcam

Read this file before making product or UI decisions.

## Product idea to preserve: Dock-first recording controls

**Status: Idea for future exploration. Not an approved change or active implementation task.**

Consider replacing Yapcam's always-visible floating recording toolbar with a more native, less intrusive **Dock-first** experience:

- **Idle:** Yapcam lives in the regular macOS Dock. Clicking its icon brings up a small recording panel, ideally visually anchored just above the Dock.
- **Recording:** Show recording state on Yapcam's Dock icon (for example a red badge); provide quick timer, pause, and stop controls in a compact panel.
- **After recording:** Open the existing Yapcam editor as usual.
- **Fallback:** Retain the current draggable floating toolbar as an optional mode, especially for multi-monitor setups and users who auto-hide the Dock.

**Important macOS constraint:** Public APIs such as `NSDockTile` allow customizing Yapcam's own Dock tile/badge, and the app can provide a Dock context menu. They do **not** allow inserting an arbitrary multi-button toolbar into Apple's system Dock. A practical prototype would use a separate `NSPanel` or equivalent app-owned window, visually associated with the Dock rather than modifying the Dock itself. Carefully test Dock auto-hide, positioning, screen changes, full-screen apps, and multiple monitors.

**Before implementation:** Compare friction and discoverability against the current toolbar; prototype and validate first. Do not remove or rewrite the existing floating bar solely because of this note.

Origin: product discussion on 2026-10-25. This note exists so future coding agents encounter and retain the idea.
