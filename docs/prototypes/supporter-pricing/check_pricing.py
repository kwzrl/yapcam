"""Browser checks for the self-contained supporter concept.

Requires Python 3.10+ and Playwright. Runtime page has no dependencies.
Run: python3 check_pricing.py
Set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH when Chromium is not on PATH.
"""
from __future__ import annotations
import argparse
import functools
import os
from pathlib import Path
import shutil
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent

class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dom-only', action='store_true', help='Render local HTML without navigation; does not test HTTP routing.')
    args = parser.parse_args()
    source = (ROOT / 'pricing' / 'index.html').read_text()
    def load(target):
        if args.dom_only:
            target.set_content(source, wait_until='domcontentloaded')
        else:
            response = target.goto(url)
            assert response and response.status == 200
    handler = functools.partial(QuietHandler, directory=str(ROOT))
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}/pricing/'
    screenshots = ROOT / 'screenshots'
    screenshots.mkdir(exist_ok=True)
    executable = os.environ.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH') or shutil.which('chromium')
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=executable, args=['--no-sandbox'])
            context = browser.new_context(viewport={'width': 1440, 'height': 1000}, device_scale_factor=1)
            page = context.new_page()
            errors: list[str] = []
            external_requests: list[str] = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: external_requests.append(request.url) if not request.url.startswith(url.removesuffix('pricing/')) else None)
            load(page)
            assert page.title() == 'Feed the monkeys. — Yapcam supporter concept'
            assert page.locator('#amount').inner_text() == '€9'
            assert page.get_by_role('radio', name='One-time', exact=True).is_checked()
            page.screenshot(path=str(screenshots / 'desktop.png'), full_page=True)
            page.screenshot(path=str(screenshots / 'desktop-hero.png'))
            for mode, amount in [('monthly', '€3'), ('yearly', '€30'), ('once', '€9')]:
                page.locator(f'label:has(input[value="{mode}"])').click()
                assert page.locator('#amount').inner_text() == amount
                if mode == 'yearly':
                    assert '€30 billed yearly' in page.locator('#billing-copy').inner_text()
                    assert 'Renews annually' in page.locator('#billing-copy').inner_text()
                page.locator('#support-button').click()
                assert page.locator('#support-dialog').is_visible()
                assert page.locator('#dialog-amount').inner_text() == amount
                assert 'No money is collected' in page.locator('#dialog-safety').inner_text()
                page.keyboard.press('Escape')
                assert not page.locator('#support-dialog').is_visible()
                assert page.locator('#support-button').evaluate('(el) => el === document.activeElement')
            # Native radio keyboard behavior.
            page.get_by_role('radio', name='One-time', exact=True).focus()
            page.keyboard.press('ArrowRight')
            assert page.get_by_role('radio', name='Monthly', exact=True).is_checked()
            assert page.locator('#amount').inner_text() == '€3'
            page.locator('#support-button').click()
            # Native dialog focus stays in the modal.
            for _ in range(6):
                page.keyboard.press('Tab')
                assert page.evaluate('document.querySelector("dialog").contains(document.activeElement)')
            page.locator('#thank-you-button').click()
            assert page.locator('#dialog-title').inner_text() == 'A monkey has been fed.'
            assert page.locator('#demo-count').inner_text() == 'Bananas in this preview: 1. No real transactions.'
            assert 'No payment was made' in page.locator('#demo-status').inner_text()
            page.screenshot(path=str(screenshots / 'thank-you.png'))
            page.locator('#thank-you-button').click()
            assert not page.locator('#support-dialog').is_visible()
            page.get_by_role('button', name='Studio chrome', exact=True).click()
            assert 'chrome' in page.locator('#webcam').get_attribute('class')
            assert page.get_by_role('button', name='Studio chrome', exact=True).get_attribute('aria-pressed') == 'true'
            assert 'chrome' in page.locator('#webcam svg').get_attribute('aria-label')
            page.get_by_role('button', name='Banana gold', exact=True).click()
            assert 'chrome' not in page.locator('#webcam').get_attribute('class')
            page.get_by_text('Am I buying an actual webcam?', exact=True).click()
            assert page.locator('details[open]').count() == 1
            assert 'not hardware' in page.locator('details[open]').inner_text()
            page.get_by_text('Am I buying an actual webcam?', exact=True).click()
            for width in [320, 390, 768, 1024, 1440, 1920]:
                page.set_viewport_size({'width': width, 'height': 900})
                load(page)
                assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'), f'Overflow at {width}px'
                page.locator('label:has(input[value="yearly"])').click()
                assert page.locator('#amount').inner_text() == '€30'
                assert page.locator('#billing-copy').bounding_box()['height'] > 0
                if width == 390:
                    page.screenshot(path=str(screenshots / 'mobile.png'), full_page=True)
                    page.locator('#support-button').click()
                    assert page.locator('#support-dialog').is_visible()
                    page.screenshot(path=str(screenshots / 'mobile-dialog.png'))
                    page.locator('#close-dialog').click()
            load(page)
            page.locator('#support-button').click()
            page.locator('#thank-you-button').click()
            assert 'preview: 1.' in page.locator('#demo-count').inner_text(), 'Demo counter must not persist'
            if not args.dom_only:
                assert page.evaluate('localStorage.length') == 0
                assert page.evaluate('sessionStorage.length') == 0
            assert not context.cookies()
            assert not errors, errors
            assert not external_requests, external_requests
            # Reduced motion and no-JS content remain readable.
            page.locator('#close-dialog').click()
            page.emulate_media(reduced_motion='reduce')
            assert page.evaluate('getComputedStyle(document.documentElement).scrollBehavior') == 'auto'
            no_js = browser.new_context(java_script_enabled=False, viewport={'width': 390, 'height': 844})
            basic = no_js.new_page()
            load(basic)
            assert basic.get_by_role('heading', name='Feed the monkeys.').is_visible()
            assert basic.locator('noscript').is_visible()
            assert basic.get_by_role('link', name='Download for Mac').get_attribute('href').endswith('Yapcam.dmg')
            no_js.close()
            browser.close()
            print('PASS: pricing modes, renewal disclosures, keyboard radios, dialog focus/Escape/return, demo-only thank-you, finishes, FAQ, six responsive widths, no external requests/cookies, reduced motion, no-JS fallback.')
            print('Harness: DOM-only (HTTP route/storage origin not tested)' if args.dom_only else 'Harness: HTTP /pricing/')
            print(f'Screenshots: {screenshots}')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

if __name__ == '__main__':
    main()
