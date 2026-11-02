# Auftrag: Yapcam /pricing – Feed the Monkeys

## Ziel und Freigabe

Baue eine neue, eigenständige `/pricing`-Seite im **tatsächlich bestehenden Yapcam-Website-Design**. Sie soll freiwillige Unterstützung für die Entwickler erklären und das Konzept einer absichtlich unnötigen Premium-Webcam als kosmetisches Dankeschön erlebbar machen. Kilian hat den Prototyp freigegeben. **Nicht freigegeben sind echte Zahlungen, ein Produktions-Deployment oder Änderungen an der kostenlosen App.**

Ein klickbarer Referenzprototyp liegt neben diesem Auftrag unter `pricing/index.html`. Er enthält bereits responsive Darstellung, alle drei Zahlungsrhythmen, Gold-/Chrom-Vorschau und einen demonstrativen Dankeschön-Dialog. Nutze ihn als Ausgangspunkt für Inhalt und Interaktion, nicht als verbindliches neues Designsystem.

## Zuerst den richtigen Arbeitsbereich finden

1. Lies `AGENTS.md` und alle im Website-Projekt geltenden Hinweise. Prüfe Branch, Arbeitsbaum, offene Änderungen und bestehende Agentenarbeit. Nichts überschreiben oder zurücksetzen.
2. Das erreichbare GitHub-Repo `kwzrl/yapcam` ist das Swift-/Rust-App-Repo. Der zuletzt bekannte lokale Website-Arbeitsbereich ist `~/yapcam-website`. Prüfe dort den tatsächlichen Stack und Git-Remote. Das Webprojekt war für die Erstellung dieses Prototyps nicht erreichbar.
3. Arbeite in einem separaten Website-Branch bzw. Worktree. Ändere weder die App, die Dock-/Floating-Bar-Idee noch andere offene Aufgaben.
4. Übernimm Header, Footer, Typografie, Abstände, Buttons, Responsive-Regeln und Assets aus der vorhandenen Website. Der Referenzentwurf verwendet nur die bekannte Richtung: Schwarz, große weiße Headlines, Gelb `#fad52a`, ruhige hochwertige Produktinszenierung. Ein exakter Designabgleich steht noch aus.

## Produktregeln

- Aufnahme, Bearbeitung und lokale Exporte bleiben kostenlos. Keine schlechtere Gratis-Version, Wasserzeichen, künstlichen Limits oder produktiven Vorteile für Unterstützer.
- Unterstützung finanziert die Menschen hinter Yapcam. Die Monkey Cam ist ein freiwilliges kosmetisches Dankeschön für die Webcam-Überlagerung, keine Hardware und keine bessere Kameraqualität.
- Alle Zahlungsrhythmen erhalten dasselbe kosmetische Extra. Keine Bronze-/Gold-/VIP-Funktionsstufen.
- Vorgeschlagene spätere Regel: Nach der ersten erfolgreichen Zahlung bleibt das Extra dauerhaft erhalten, auch nach Kündigung. Im Prototyp wird weder bezahlt noch etwas in der App freigeschaltet.
- Kein pauschales Versprechen, dass jede denkbare zukünftige Team-/Cloud-Leistung kostenlos sein wird. Der heutige kostenlose Recording-Core wird nicht eingeschränkt.
- Keine erfundenen Unterstützerzahlen, Spendenziele, Testimonials oder Geld-Ranglisten. Ein Banana Counter muss deutlich als lokale Demo gekennzeichnet sein. Keine Behauptung einer gemeinnützigen Spende.
- Keine Änderungen an der Repository-Lizenz. Die aktuell gelesene README nennt Apache 2.0, nicht MIT.

## Inhalt und Interaktion

Marketingtext auf Englisch. Kern: **“Feed the monkeys.” / “Yapcam is free. Bananas aren't.”**

Zeige zuerst die Monkey Cam als hochwertig inszeniertes, absurd unnötiges Extra. Die Referenz bietet Banana Gold und Studio Chrome zur Vorschau; beide sind Teil desselben Konzepts. Die gezeichnete Figur und das Logo sind Platzhalter. Vorhandene freigegebene Yapcam-Assets haben Vorrang. Erzeuge keine neue verbindliche Markenidentität nebenbei.

Eine kostenlose Yapcam-Karte und eine Supporter-Karte reichen. In der Supporter-Karte gibt es **One-time / Monthly / Yearly**. Standard ist One-time, ohne vorausgewähltes Abo. Vorläufige Entwurfspreise:

| Rhythmus | Preis | Erklärung |
| --- | --- | --- |
| One-time | €9 | Einmalig, kein Abo |
| Monthly | €3 / Monat | Monatliche automatische Verlängerung bis zur Kündigung |
| Yearly | €30 / Jahr | €30 jährlich abgerechnet, jährliche automatische Verlängerung bis zur Kündigung |

Beim Jahresmodell ist €2,50/Monat nur ein Vergleichswert. Die tatsächliche jährliche Abrechnung muss unmittelbar sichtbar bleiben. Zwölf Monatszahlungen ergeben €36; die Beispielersparnis beträgt €6. Preise sind **nicht final beschlossen** und müssen zentral konfigurierbar bleiben.

Der Support-Button öffnet ausschließlich eine als Demo markierte Vorschau. Ein weiterer Klick zeigt **“A monkey has been fed. Development continues.”** Dabei muss klar stehen, dass keine Zahlung und keine Freischaltung stattgefunden haben. Die Demo zählt nur im aktuellen Seitenaufruf, ohne Datenbank oder persistente Berechtigungen.

FAQ: kostenlose Nutzung, digitales Extra statt Hardware, Verhalten nach Kündigung, jährliche Abrechnung, Prototyp ohne Zahlungen. Navigation und Download-Links müssen aus dem echten Website-Projekt kommen. Keine erfundenen Ziele oder toten Checkout-Buttons.

## Technische Grenzen

Bestehenden Stack nutzen, keine neue Framework-Migration oder unnötigen Libraries. Den Standalone-Entwurf in echte Komponenten überführen; CSS lokal begrenzen und vorhandene Tokens nutzen. Inline-Script/CSS nicht blind in eine Website mit anderer CSP kopieren.

Kein Stripe, kein Account-System, kein Live-Abo, keine App-Entitlements, keine Telemetrie und kein Public-Supporter-Backend in dieser Aufgabe. Ein echter Checkout und seine Geschäfts-/Rechtstexte sind eine separat freizugebende Folgephase. Client-State darf niemals als Zahlungsnachweis dienen.

Spätere App-Idee lediglich dokumentieren: ein zurückhaltender “Feed the Monkeys”-Eintrag in den Einstellungen bzw. ein dauerhaft ausblendbarer Support-Hinweis nach erfolgreicher Nutzung. Kein wiederkehrendes Popup und keine Einblendung während einer Aufnahme. **Jetzt nicht in Swift implementieren.**

## Abnahme und Übergabe

- `/pricing` funktioniert im tatsächlichen Website-Projekt, ohne bestehende Seiten zu verändern.
- Alle Zahlungsrhythmen aktualisieren Betrag, Zeitraum und Verlängerungshinweis konsistent; die Dialogvorschau übernimmt dieselbe Auswahl.
- Tastaturbedienung, sichtbarer Fokus, Radio-Buttons, Dialog-Fokus, Escape und Fokus-Rückgabe funktionieren. Reduced Motion wird respektiert.
- Keine horizontalen Überläufe bei 320, 390, 768, 1024, 1440 und 1920 Pixeln. Mobile und Desktop visuell prüfen; Safari/iPhone separat testen.
- Keine echten Zahlungen, keine Fake-Kundendaten und keine Zusage, dass die Monkey Cam bereits in der App existiert.
- Build/Lint/Tests des echten Webprojekts ausführen. Vorhandene Fehler von neu verursachten Fehlern trennen.
- Liefere Branch/Commit, lokale Preview-Anleitung oder ausdrücklich freigegebene Preview-URL, Desktop-/Mobile-Screenshots, Testresultate und verbleibende Entscheidungen. Nicht selbstständig nach `main` mergen oder produktiv veröffentlichen.

## Bereits geprüft und noch offen

Der Referenzentwurf wurde in Chromium als lokal eingesetztes HTML geprüft: Interaktionen, Abrechnungsanzeigen, Dialog, Tastatur, Finish-Auswahl, FAQ, sechs Viewportbreiten, Reduced Motion und No-JS-Inhalt. Keine externen Requests oder Cookies im Test. Der lokale HTTP-Aufruf war in der Erstellungsumgebung blockiert, daher lief die Browserprüfung mit `--dom-only`. HTTP-Routing, echte Website-Integration, Safari/iPhone und native App-Integration sind **nicht** geprüft. Tests stehen in `check_pricing.py`.
