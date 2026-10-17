# Übergabe Laptop → Mac mini: Agentic Editor (18.10.2026)

Branch **`agentic/editor`** auf GitHub (Stand dieser Datei). 66 Commits über `origin/main` (1a9c309), `main` ist
unberührt. Gebaut und getestet auf dem Laptop (M1, 8 GB): Core 162, stdio 12, XCTest 288, Swift Testing 839 Tests grün.

## Was drin ist

1. **Toolbar (laptop/ui):** Glas-Kit `Sources/YapcamDesign/`, Variante B (abgerundet, Teller, Haarlinien), Record-Button
   neben der Leiste, schmale vertikale Leiste, Edit-Button mit letzter Aufnahme, Library-Popover, Onboarding pro
   Freigabe mit Hilfeseite (Restart, `tccutil reset`), App-Icon v10.
2. **Editor im neuen Design** (`Sources/YapcamEditor`): angedocktes Layout, neutrale Töne (`Yap.ground` #1C1C1E,
   `Yap.dock` #242426), voller Inspector mit Icon-Leiste (keine Funktion verloren), Zeitleiste auf dem Grund mit
   1-px-Abspielkopf, Spurnamen, Umschalter Timeline/Transcript, Bausteine-Leiste (Title, Spotlight, Text).
   Vorlage: Design-Lab `--design-lab`, Seite "Editor".
3. **Agent (opt-in, Chat-Icon oben links):**
   - In-App-MCP-Server `127.0.0.1:7777` (Token in `defaults read mov.yapcam.Yapcam agent.mcp.token`,
     Port per `-agent.mcp.port`), arbeitet auf dem offenen Dokument, jede Änderung = 1 Undo-Schritt, erscheint im Chat.
   - Chat startet lokales Claude Code (`claude -p`, Opus, `--resume` pro Dokument = Gedächtnis). Externe Agents:
     "Copy connect command".
   - Werkzeuge: Lesen (`moments`, `read_*`, `project_summary`), Augen (`capture` Kontaktbögen über den echten
     Renderer, `grab`, `filmstrip`, `waveform`, `view_changes` mit bbox), Prüfen (`check`), Absicht
     (`cut_words`, `tighten_pauses`, `remove_fillers`, `trim_start_to_first_word`, `zoom_on_click` mit `include`,
     `start_s`/`end_s`), roh (`apply`, `batch`), `transcribe`, `seek`, `select`, `undo`/`redo`/`save`.
   - Handbuch für den Agent in `core/agent-docs/` (playbook, craft, tools, 3 Beispiele, chat), per MCP
     `instructions`, Ressourcen `yapcam://…` und Prompts ausgeliefert.
   - Pixel-Hinweise: Die App berechnet Seitenwechsel und geänderte Regionen selbst und reicht sie an
     `moments`/`zoom_on_click`/`check` weiter.
   - Aufnahme schreibt jetzt `focus`-Events (App, Fenstertitel) in events.jsonl (`Sources/YapcamCapture/FocusEvents.swift`).
4. **Spike 1:** stdio-MCP `tools/yapcam-mcp` (dünner Wrapper um dieselbe Core-Logik `core/src/mcp.rs`,
   `mcp_craft.rs`, `agent_docs.rs`) für geschlossene Projekte.
5. **Eval:** `tools/eval/` (make_golden.py, run_eval.py, RUBRIC.md). Golden-Pakete liegen NICHT im Repo; neu erzeugen:
   Python-venv mit Pillow, `python tools/eval/make_golden.py` (ca. 2 min, nutzt `say`), dann
   `python tools/eval/run_eval.py <tighten|walkthrough|walkthrough-nofocus|changelog|nice|conversation>`
   (eigener Port, eigener Token im Argument-Domain, kostet echte Claude-Aufrufe, ca. 0,15 bis 0,45 $ pro Szenario).

## Messergebnisse (Eval, 4 Runden)

Durchgehend: 0 Schnitte im Wort, alle Füllwörter/Fehlstarts raus, Start 0,1 s vor dem ersten Wort, Ende ≤ 0,8 s,
kein Zoom auf versehentliche Klicks, Unterhaltung ("mach kürzer", "undo") korrekt. Behoben über die Runden: Zoom auf
leere neue Seite (auch ohne Fensterdaten), Tippen/Laden als Stille gekürzt, Kontext abgeschnitten (`include`),
unlesbare Kontaktbögen. Letzter Bug (Runde 3): Intention-Tools erhöhten die Revision nicht, behoben in `db86998`
mit Regressionstest. Runde 4 lief bei Übergabe noch (Branch `delegate/ae-eval`, Report-Abschnitt "Runde 4").

## Bauen auf dem Mac mini

```sh
git fetch origin && git checkout agentic/editor && git pull
scripts/setup-signing.sh        # falls "Yapcam Dev Signing" fehlt (sonst erkennt macOS die Freigaben nicht)
CARGO_BUILD_JOBS=4 scripts/build-app.sh debug   # linkt nach Rust-Änderungen jetzt zuverlässig neu
open build/Yapcam.app
swift test -j 2 && cargo test --manifest-path core/Cargo.toml && cargo test --manifest-path tools/yapcam-mcp/Cargo.toml
```

## Für den Lead offen

- **Integration nach main:** `agentic/editor` baut den Editor um. `team/editor` und `team/ui` fassen dieselben Dateien an
  (EditorView, EditorChrome, Inspector, Timeline*, ToolbarView). Vorschlag: Editor-Team pausiert, Lead merged
  `agentic/editor` zuerst, Teams rebasen danach.
- **Wackelige Tests (nicht von dieser Arbeit):** `Round6StartDecisionTests.backToBackSettingChangesWithAnObserverDoNotTrap`
  (Timing), `ExportPlanningWiringTests.gifDefaultsPresetsAndEstimateComeFromRender` (Reihenfolge, gemerkte
  Export-Einstellungen), `AgentPlaybookTests` Fake-Claude-Timeout unter Last. Einzeln immer grün.
- **Core-Wünsche (ae-mcp):** Transkript-Abfrage im Core statt Snapshot-Klon; expliziter Read-only-Snapshot-Konstruktor;
  Writer-Koordination für Live-Modus mit mehreren Prozessen.
- **THIRD_PARTY.md:** Abhängigkeiten von `tools/yapcam-mcp` (serde-Familie, MIT/Apache) eintragen.
- **Nächste Schritte Produkt:** gestrichelte Vorschläge (Annehmen/Ablehnen pro Änderung), Callout-Baustein,
  `check` meldet `last_edit_unverified`, `read_events` mit `type`-Filter, Spike-1-Bewertung mit echten Aufnahmen
  MIT Mikro (die bisherigen Laptop-Aufnahmen haben kein Mikro), echte Spracherkennung über `transcribe` live prüfen.
- **Entscheidungen von Kilian** (verbindlich): Agent ergänzt nur und ist opt-in; voller Inspector bleibt; Chat immer
  links angedockt; keine Wärme in den Tönen; Gelb nur für Timecodes/Werte; Haarlinien statt gefräster Linien;
  Agent-Änderungen sofort angewendet mit Keep/Undo (gestrichelte Vorschläge kommen später).
- **Konzept-Doc:** https://claude.ai/code/artifact/9eaccdde-49d1-429f-82c8-12d688717728 (Inspector- und
  Opt-in-Entscheidung dort noch nachziehen).

## Referenzen

Design-Regeln und Arbeitsweise: Lab-Code `Sources/YapcamUI/Support/DesignLabEditor*.swift`, Kit `Sources/YapcamDesign/`.
Agent-Architektur: `Sources/YapcamUI/Agent/` (AgentServer, AgentVision), `Sources/YapcamEditor/Chat/`, `core/src/mcp*.rs`.
