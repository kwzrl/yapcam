# Yapcam supporter pricing concept

A self-contained, non-payment prototype for **Feed the Monkeys**. Start the agent handoff with [AGENT_BRIEF.md](AGENT_BRIEF.md).

## Open the prototype

Open `pricing/index.html` directly in a modern browser. All styles, JavaScript and illustrations are inline; there are no CDN, font or image dependencies.

To preview the intended URL locally, run from this directory:

```sh
python3 -m http.server 4173 --bind 127.0.0.1
```

Then open `http://127.0.0.1:4173/pricing/`. This is a prototype route under a local server, **not** a deployed `yapcam.app/pricing` page.

## Scope

- Black/white/yellow (`#fad52a`) concept direction, not a verified match to the unavailable website source.
- Free-app card and one optional supporter card; one-time/monthly/yearly selection.
- Example prices of €9 once, €3 monthly or €30 annually. These are design assumptions, not a live offer or approved pricing.
- Gold/chrome digital webcam-frame preview. Illustration and logo are temporary, self-contained SVG/CSS assets.
- Explicit demo dialog and local, non-persistent banana count. No checkout, payments, account, analytics or app entitlements.
- Keyboard controls, reduced-motion styles, responsive layout and FAQ.
- Repository license remains unchanged. App facts and download URL were taken from the existing Yapcam README.

The connected GitHub repository contains the native app, not the website. This folder intentionally avoids changing either the app or any production site. The agent must integrate the concept into the actual website workspace after inspecting its design and stack.

## Browser checks

Tests require Python 3.10+ and Playwright; the page itself requires no packages. In a suitable development environment:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install playwright
python -m playwright install chromium
python check_pricing.py
```

The harness uses Chromium on PATH, `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` when supplied, or Playwright's bundled Chromium. Screenshots are generated under `screenshots/`.

When browser navigation to a local server is unavailable:

```sh
python check_pricing.py --dom-only
```

This sets the local HTML into a browser page without network navigation. It checks UI behavior, not HTTP routing. The `--dom-only` checks passed in the authoring environment. HTTP-route and origin-storage assertions were not run there. Safari/iPhone and integration into the real website remain untested.

To change proposed prices, edit `SUPPORT_OPTIONS` and the corresponding static fallback, annual FAQ and assertions. Never treat browser state as proof of payment.
