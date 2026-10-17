#!/usr/bin/env python3
"""Build the agent-eval golden set: realistic .yapcam packages with speech, clicks and typing.

Kilian's real recordings have no microphone, so every package here is synthetic but follows docs/FORMATS.md:
a rendered fake web app (screen.mov, H.264), a `say` voice track as the microphone (mic.m4a), input events
(moves, clicks, keys, focus with window titles) and recording/transcript.json with exact word timings
(each word is synthesized on its own, so its start/end in the track is known, not estimated).

Every package also gets golden.json: the scenario prompts and the labels the scorer needs (filler word
indices, false-start ranges, meaningful vs accidental clicks, the sentences a changelog must keep).

Needs: macOS `say`, ffmpeg, Pillow (`python3 -m venv .venv && .venv/bin/pip install pillow`).
Usage: make_golden.py [--out ~/yapcam-spike/eval/golden] [--only tighten,...]
"""
import argparse
import array
import json
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H, FPS, RATE = 1440, 900, 30, 48000
VOICE = 'Samantha'
CACHE = Path.home() / 'yapcam-spike/eval/.tts-cache'
REPO = Path(__file__).resolve().parents[2]
FILLERS = {'um', 'uh', 'erm', 'er', 'hmm'}

# ---------------------------------------------------------------------------------------------- the fake app UI
# Every page is a list of widgets: (kind, id, rect[x,y,w,h], label). Kinds: button, primary, field, text, card,
# chip (selectable), toggle, nav (sidebar item), progress. Rects are capture points (= pixels, scale 1).
SIDEBAR = ['Projects', 'Deploys', 'Reports', 'Team', 'Settings']


def nav(active):
    return [('nav', 'nav_' + n.lower(), [24, 120 + i * 52, 200, 40], n) for i, n in enumerate(SIDEBAR)] + [('active', None, None, active)]


PAGES = {
    'projects': nav('Projects') + [
        ('text', None, [280, 110, 600, 40], 'Projects'),
        ('primary', 'btn_new', [1180, 104, 200, 48], 'New project'),
        ('card', None, [280, 190, 520, 150], 'web-frontend|Live · fra1 · 2 min ago'),
        ('card', None, [840, 190, 520, 150], 'auth-service|Live · iad1 · 1 h ago'),
        ('card', None, [280, 370, 520, 150], 'docs-site|Live · fra1 · yesterday'),
    ],
    'new_project': nav('Projects') + [
        ('text', None, [280, 110, 600, 40], 'New project'),
        ('label', None, [280, 190, 400, 30], 'Project name'),
        ('field', 'name', [280, 226, 560, 52], ''),
        ('label', None, [280, 320, 400, 30], 'Region'),
        ('chip', 'region_fra', [280, 356, 180, 52], 'Frankfurt'),
        ('chip', 'region_iad', [480, 356, 180, 52], 'Virginia'),
        ('chip', 'region_hnd', [680, 356, 180, 52], 'Tokyo'),
        ('primary', 'btn_create', [280, 470, 240, 56], 'Create project'),
    ],
    'deploying': nav('Projects') + [
        ('text', None, [280, 110, 800, 40], '{name}'),
        ('label', None, [280, 190, 800, 30], 'Creating project and first deploy…'),
        ('progress', 'progress', [280, 236, 700, 18], ''),
    ],
    'live': nav('Projects') + [
        ('text', None, [280, 110, 800, 40], '{name}'),
        ('badge', None, [280, 180, 120, 36], 'Live'),
        ('label', None, [280, 240, 800, 30], 'https://{name}.acme.app'),
        ('button', 'btn_copy', [280, 290, 180, 48], 'Copy URL'),
        ('button', 'btn_logs', [480, 290, 180, 48], 'View logs'),
    ],
    'reports': nav('Reports') + [
        ('text', None, [280, 110, 600, 40], 'Reports'),
        ('label', None, [280, 190, 400, 30], 'Date range'),
        ('chip', 'range_7', [280, 226, 200, 52], 'Last 7 days'),
        ('chip', 'range_30', [500, 226, 200, 52], 'Last 30 days'),
        ('chip', 'range_90', [720, 226, 200, 52], 'Last 90 days'),
        ('card', None, [280, 310, 1080, 300], 'Requests per day|{chart}'),
        ('primary', 'btn_export', [1180, 104, 180, 48], 'Export CSV'),
    ],
    'settings': nav('Settings') + [
        ('text', None, [280, 110, 600, 40], 'Settings'),
        ('tab', 'tab_general', [280, 180, 160, 44], 'General'),
        ('tab', 'tab_appearance', [450, 180, 160, 44], 'Appearance'),
        ('tab', 'tab_billing', [620, 180, 160, 44], 'Billing'),
        ('label', None, [280, 260, 700, 30], '{settings_body}'),
        ('toggle', 'toggle_dark', [280, 310, 90, 44], 'Dark mode'),
        ('field', 'billing_email', [280, 380, 560, 52], ''),
        ('primary', 'btn_save', [280, 460, 160, 52], 'Save'),
    ],
    'team': nav('Team') + [
        ('text', None, [280, 110, 600, 40], 'Team'),
        ('primary', 'btn_invite', [1180, 104, 180, 48], 'Invite'),
        ('card', None, [280, 190, 1080, 70], 'Kilian W. · Owner'),
        ('card', None, [280, 270, 1080, 70], 'Mara K. · Developer'),
        ('field', 'invite_email', [280, 380, 560, 52], ''),
        ('button', 'btn_send', [860, 380, 160, 52], 'Send invite'),
    ],
    'deploys': nav('Deploys') + [
        ('text', None, [280, 110, 600, 40], 'Deploys'),
        ('primary', 'btn_deploy', [1180, 104, 180, 48], 'Deploy now'),
        ('card', None, [280, 190, 1080, 70], '#412 · main · 31 s · yesterday'),
        ('card', None, [280, 270, 1080, 70], '#411 · main · 29 s · 2 days ago'),
        ('progress', 'progress', [280, 380, 700, 18], ''),
        ('label', None, [280, 410, 700, 30], '{deploy_status}'),
    ],
}


def font(size, bold=False):
    for path in (['/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Helvetica.ttc'] if not bold else
                 ['/System/Library/Fonts/SFNSRounded.ttf', '/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Helvetica.ttc']):
        try: return ImageFont.truetype(path, size)
        except OSError: continue
    return ImageFont.load_default()


F = {'title': font(30, True), 'body': font(20), 'small': font(17), 'app': font(17, True)}


def render(state):
    dark = state.get('dark', False)
    bg, panel, ink, mute, line = ((22, 24, 30), (32, 35, 44), (236, 238, 243), (150, 156, 170), (55, 60, 72)) if dark else \
        ((246, 247, 250), (255, 255, 255), (24, 28, 38), (110, 116, 130), (222, 225, 232))
    accent = (52, 108, 246)
    img = Image.new('RGB', (W, H), bg)
    d = ImageDraw.Draw(img)
    # Browser-ish chrome and app header.
    d.rectangle([0, 0, W, 44], fill=(228, 230, 235) if not dark else (40, 43, 52))
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([16 + i * 22, 15, 30 + i * 22, 29], fill=c)
    d.rounded_rectangle([420, 9, 1020, 35], 8, fill=panel)
    d.text((440, 13), state.get('url', 'console.acme.app/' + state['page'].replace('_', '-')), font=F['small'], fill=mute)
    d.rectangle([0, 44, 248, H], fill=panel)
    d.line([248, 44, 248, H], fill=line, width=1)
    d.text((24, 64), '▲ Acme Cloud', font=F['app'], fill=ink)
    widgets = PAGES[state['page']]
    active = next(l for k, _, _, l in widgets if k == 'active')
    fmt = {'name': state.get('fields', {}).get('name') or 'billing-api', 'chart': '', 'settings_body': state.get('settings_body', 'Workspace name: Acme'),
           'deploy_status': state.get('deploy_status', '')}
    for kind, wid, rect, label in widgets:
        if kind == 'active' or (wid in state.get('hidden', ())): continue
        x, y, w, h = rect
        label = label.format(**fmt)
        if kind == 'nav':
            if label == active: d.rounded_rectangle([x, y, x + w, y + h], 8, fill=(232, 238, 254) if not dark else (45, 55, 85))
            d.text((x + 16, y + 9), label, font=F['body'], fill=accent if label == active else ink)
        elif kind == 'text':
            d.text((x, y), label, font=F['title'], fill=ink)
        elif kind == 'label':
            d.text((x, y), label, font=F['body'], fill=mute)
        elif kind in ('button', 'primary'):
            pressed = state.get('pressed') == wid
            fill = (accent if kind == 'primary' else panel)
            if pressed: fill = tuple(max(0, c - 40) for c in fill)
            d.rounded_rectangle([x, y, x + w, y + h], 10, fill=fill, outline=None if kind == 'primary' else line, width=1)
            tw = d.textlength(label, font=F['body'])
            d.text((x + (w - tw) / 2, y + (h - 24) / 2), label, font=F['body'], fill=(255, 255, 255) if kind == 'primary' else ink)
        elif kind == 'field':
            focused = state.get('focus') == wid
            d.rounded_rectangle([x, y, x + w, y + h], 8, fill=panel, outline=accent if focused else line, width=2 if focused else 1)
            text = state.get('fields', {}).get(wid, '')
            placeholder = {'name': 'my-project', 'billing_email': 'billing@company.com', 'invite_email': 'name@company.com'}.get(wid, '')
            d.text((x + 14, y + 13), text or placeholder, font=F['body'], fill=ink if text else mute)
            if focused:
                cx = x + 14 + d.textlength(text, font=F['body']) + 2
                d.line([cx, y + 12, cx, y + h - 12], fill=accent, width=2)
        elif kind in ('chip', 'tab'):
            on = wid in state.get('selected', ())
            d.rounded_rectangle([x, y, x + w, y + h], 10 if kind == 'chip' else 6, fill=(232, 238, 254) if on and not dark else ((45, 55, 85) if on else panel),
                                outline=accent if on else line, width=2 if on else 1)
            tw = d.textlength(label, font=F['body'])
            d.text((x + (w - tw) / 2, y + (h - 24) / 2), label, font=F['body'], fill=accent if on else ink)
        elif kind == 'toggle':
            on = state.get('dark', False)
            d.rounded_rectangle([x, y, x + 80, y + h], h // 2, fill=accent if on else line)
            knob = x + 80 - h + 4 if on else x + 4
            d.ellipse([knob, y + 4, knob + h - 8, y + h - 4], fill=(255, 255, 255))
            d.text((x + 100, y + 9), label, font=F['body'], fill=ink)
        elif kind == 'card':
            d.rounded_rectangle([x, y, x + w, y + h], 12, fill=panel, outline=line, width=1)
            head, _, sub = label.partition('|')
            d.text((x + 20, y + 18), head, font=F['body'], fill=ink)
            if sub: d.text((x + 20, y + 50), sub, font=F['small'], fill=mute)
            if head == 'Requests per day':
                rng = state.get('range', 7)
                vals = [((i * 37) % 23 + 8 + (i % 5) * 3) for i in range(rng)]
                bw = (w - 60) / rng
                for i, v in enumerate(vals):
                    bx = x + 30 + i * bw
                    d.rectangle([bx, y + h - 20 - v * 8, bx + max(2, bw - 4), y + h - 20], fill=accent)
        elif kind == 'progress':
            p = state.get('progress')
            if p is None: continue
            d.rounded_rectangle([x, y, x + w, y + h], h // 2, fill=line)
            d.rounded_rectangle([x, y, x + max(h, w * p), y + h], h // 2, fill=accent)
        elif kind == 'badge':
            d.rounded_rectangle([x, y, x + w, y + h], h // 2, fill=(220, 247, 230))
            d.text((x + 34, y + 6), label, font=F['body'], fill=(20, 120, 60))
    if state.get('toast'):
        t = state['toast']
        tw = d.textlength(t, font=F['body'])
        d.rounded_rectangle([W - tw - 80, H - 90, W - 30, H - 36], 12, fill=(30, 34, 44))
        d.text((W - tw - 55, H - 76), t, font=F['body'], fill=(255, 255, 255))
    return img


def center(page, wid):
    for _, i, rect, _ in PAGES[page]:
        if i == wid: return [rect[0] + rect[2] / 2, rect[1] + rect[3] / 2]
    raise KeyError(f'{wid} not on {page}')


# --------------------------------------------------------------------------------------------- scenario scripts
# A scenario is a list of beats. A beat speaks `say` (may be empty), then waits `pause` seconds. Actions are
# anchored to a word of the beat ("word": k, 0-based in the beat) or to the beat end ("after": seconds).
# Action kinds: click (target widget or "xy"), type (into the focused field), effect (state change only), wiggle.
SCENARIOS = {
    'tighten': {
        'title': 'Acme Cloud — Reports',
        'start': {'page': 'projects'},
        'lead': 2.6,
        'beats': [
            {'say': 'Um, okay. So in this video I will show you how to, uh, export a report.', 'pause': 0.45,
             'actions': [{'at': -2.2, 'do': 'wiggle'}]},
            {'say': 'So first you click on the.', 'pause': 0.7, 'false_start': True},
            {'say': 'So first you click on reports in the sidebar.', 'pause': 2.4,
             'actions': [{'word': 5, 'do': 'click', 'target': 'nav_reports', 'goto': 'reports', 'meaningful': True}]},
            {'say': 'Then you pick the date range, um, last thirty days.', 'pause': 2.8,
             'actions': [{'word': 7, 'do': 'click', 'target': 'range_30', 'select': ['range_30'], 'set': {'range': 30}, 'meaningful': True}]},
            {'say': 'And then you hit export, and, uh, the CSV downloads right away.', 'pause': 0.5,
             'actions': [{'word': 4, 'do': 'click', 'target': 'btn_export', 'toast': 'report-30d.csv downloaded', 'meaningful': True}]},
            {'say': 'That is it.', 'pause': 3.5},
        ],
        'prompts': ['Tighten this up.'],
    },
    'walkthrough': {
        'title': 'Acme Cloud — Projects',
        'start': {'page': 'projects'},
        'lead': 1.0,
        'beats': [
            {'say': 'Here is how to create a new project in Acme Cloud.', 'pause': 0.6,
             'actions': [{'word': 6, 'do': 'click', 'xy': [900, 700], 'meaningful': False, 'why': 'click on empty space'}]},
            {'say': 'Click new project in the top right.', 'pause': 0.5,
             'actions': [{'word': 1, 'do': 'click', 'target': 'btn_new', 'goto': 'new_project', 'focus': 'name', 'meaningful': True, 'name': 'New project'}]},
            {'say': 'Give it a name.', 'pause': 0.3,
             'actions': [{'after': 0.1, 'do': 'type', 'field': 'name', 'text': 'billing-api'}]},
            {'say': '', 'pause': 1.6},
            {'say': 'Pick the region closest to your users, I will take Frankfurt.', 'pause': 0.7,
             'actions': [{'word': 10, 'do': 'click', 'target': 'region_fra', 'select': ['region_fra'], 'meaningful': True, 'name': 'Frankfurt'}]},
            {'say': 'And hit create.', 'pause': 0.4,
             'actions': [{'word': 1, 'do': 'click', 'xy': [430, 560], 'meaningful': False, 'why': 'missed the button'},
                         {'word': 2, 'do': 'click', 'target': 'btn_create', 'goto': 'deploying', 'set': {'progress': 0.05}, 'meaningful': True, 'name': 'Create project'},
                         {'after': 0.6, 'do': 'effect', 'set': {'progress': 0.35}}, {'after': 1.4, 'do': 'effect', 'set': {'progress': 0.7}},
                         {'after': 2.4, 'do': 'effect', 'goto': 'live', 'set': {'progress': None}}]},
            {'say': '', 'pause': 2.6},
            {'say': 'After a few seconds it is live, and you can copy the URL from here.', 'pause': 1.2,
             'actions': [{'word': 12, 'do': 'click', 'target': 'btn_copy', 'toast': 'URL copied', 'meaningful': True, 'name': 'Copy URL'}]},
        ],
        'prompts': ['Add zooms on the clicks that matter.'],
    },
    'changelog': {
        'title': 'Acme Cloud — Settings',
        'start': {'page': 'projects'},
        'lead': 1.4,
        'beats': [
            {'say': 'Hi everyone, quick update on what we shipped this sprint.', 'pause': 0.9, 'role': 'intro'},
            {'say': 'First, there is now a dark mode.', 'pause': 0.4, 'role': 'feature', 'feature': 'dark mode'},
            {'say': 'You find it under settings, appearance.', 'pause': 0.5, 'role': 'feature', 'feature': 'dark mode',
             'actions': [{'word': 4, 'do': 'click', 'target': 'nav_settings', 'goto': 'settings', 'meaningful': True},
                         {'word': 5, 'do': 'click', 'target': 'tab_appearance', 'select': ['tab_appearance'], 'set': {'settings_body': 'Theme'}, 'meaningful': True}]},
            {'say': 'Flip the switch and the whole console goes dark.', 'pause': 1.0, 'role': 'feature', 'feature': 'dark mode',
             'actions': [{'word': 1, 'do': 'click', 'target': 'toggle_dark', 'set': {'dark': True}, 'meaningful': True}]},
            {'say': 'I actually spent a lot of time on this one, uh, because the old color tokens were a mess, but anyway.', 'pause': 1.6, 'role': 'ramble'},
            {'say': 'Second, you can now invite teammates by email.', 'pause': 0.5, 'role': 'feature', 'feature': 'invites',
             'actions': [{'word': 4, 'do': 'click', 'target': 'nav_team', 'goto': 'team', 'meaningful': True},
                         {'word': 6, 'do': 'click', 'target': 'invite_email', 'focus': 'invite_email', 'meaningful': False, 'why': 'focus field'}]},
            {'say': '', 'pause': 0.2, 'actions': [{'after': 0.0, 'do': 'type', 'field': 'invite_email', 'text': 'mara@acme.dev'}]},
            {'say': '', 'pause': 1.9},
            {'say': 'Type the address and hit send.', 'pause': 0.8, 'role': 'feature', 'feature': 'invites',
             'actions': [{'word': 4, 'do': 'click', 'target': 'btn_send', 'toast': 'Invite sent to mara@acme.dev', 'meaningful': True}]},
            {'say': 'Um, we also fixed a bunch of small bugs that I will not go through, they are in the release notes.', 'pause': 1.4, 'role': 'ramble'},
            {'say': 'Third, deploys are now about twice as fast.', 'pause': 0.4, 'role': 'feature', 'feature': 'faster deploys',
             'actions': [{'word': 3, 'do': 'click', 'target': 'nav_deploys', 'goto': 'deploys', 'meaningful': True}]},
            {'say': 'Watch this.', 'pause': 0.3, 'role': 'feature', 'feature': 'faster deploys',
             'actions': [{'word': 1, 'do': 'click', 'target': 'btn_deploy', 'set': {'progress': 0.05, 'deploy_status': 'Building…'}, 'meaningful': True},
                         {'after': 1.0, 'do': 'effect', 'set': {'progress': 0.25}}, {'after': 2.0, 'do': 'effect', 'set': {'progress': 0.45}},
                         {'after': 3.0, 'do': 'effect', 'set': {'progress': 0.65}}, {'after': 4.0, 'do': 'effect', 'set': {'progress': 0.85}},
                         {'after': 5.0, 'do': 'effect', 'set': {'progress': 1.0, 'deploy_status': 'Deployed in 14 s'}}]},
            {'say': '', 'pause': 5.4},
            {'say': 'Fourteen seconds, it used to be over thirty.', 'pause': 1.2, 'role': 'feature', 'feature': 'faster deploys'},
            {'say': 'So, yeah, uh, that is pretty much it, I think. Oh, and the docs got a new search too, but that is for next time.', 'pause': 1.0, 'role': 'ramble'},
            {'say': 'Thanks for watching, see you next sprint.', 'pause': 2.4, 'role': 'outro'},
        ],
        'prompts': ['Make a 30 second changelog clip out of this.'],
    },
    'nice': {
        'title': 'Acme Cloud — Billing',
        'start': {'page': 'projects'},
        'lead': 1.9,
        'beats': [
            {'say': 'Uh, so, this is how you change the billing email.', 'pause': 1.5},
            {'say': 'Go to settings.', 'pause': 0.4,
             'actions': [{'word': 2, 'do': 'click', 'target': 'nav_settings', 'goto': 'settings', 'meaningful': True}]},
            {'say': 'Then billing.', 'pause': 1.7,
             'actions': [{'word': 1, 'do': 'click', 'target': 'tab_billing', 'select': ['tab_billing'], 'set': {'settings_body': 'Billing contact'}, 'meaningful': True},
                         {'after': 0.8, 'do': 'click', 'xy': [1100, 650], 'meaningful': False, 'why': 'click on empty space'}]},
            {'say': 'Um, click the email field and type the new address.', 'pause': 0.3,
             'actions': [{'word': 4, 'do': 'click', 'target': 'billing_email', 'focus': 'billing_email', 'meaningful': True}]},
            {'say': '', 'pause': 0.2, 'actions': [{'after': 0.0, 'do': 'type', 'field': 'billing_email', 'text': 'finance@acme.dev'}]},
            {'say': '', 'pause': 2.4},
            {'say': 'And then, um, save.', 'pause': 0.5,
             'actions': [{'word': 3, 'do': 'click', 'target': 'btn_save', 'toast': 'Billing email updated', 'meaningful': True}]},
            {'say': 'Done, invoices now go to finance.', 'pause': 2.6},
        ],
        'prompts': ['make it nice'],
    },
}
# Scenario (e) is a conversation on a copy of the walkthrough package.
CONVERSATION = {'package': 'walkthrough', 'prompts': ['Add a zoom on the Create project click.', 'Make that zoom shorter.', 'Undo the last change.']}


# ------------------------------------------------------------------------------------------------------ speech
def tts_word(text):
    """One word as 48 kHz mono int16 samples with leading/trailing silence trimmed (cached)."""
    CACHE.mkdir(parents=True, exist_ok=True)
    key = ''.join(c if c.isalnum() else '_' for c in text.lower()) or 'blank'
    wav = CACHE / f'{VOICE}-{key}.wav'
    if not wav.exists():
        subprocess.run(['say', '-v', VOICE, '-o', str(wav), '--file-format=WAVE', f'--data-format=LEI16@{RATE}', text], check=True, timeout=60)
    with wave.open(str(wav)) as f:
        samples = array.array('h', f.readframes(f.getnframes()))
    thr = 0.02 * 32767
    first = next((i for i, v in enumerate(samples) if abs(v) > thr), 0)
    last = next((i for i in range(len(samples) - 1, -1, -1) if abs(samples[i]) > thr), len(samples) - 1)
    pad = int(0.01 * RATE)
    return samples[max(0, first - pad): last + pad]


def spoken(word):
    """What `say` should pronounce for a transcript token."""
    return word.strip('.,!?').replace('-', ' ')


# ------------------------------------------------------------------------------------------------------- build
def build(name, spec, out_root, focus=True):
    """focus=False omits focus/window-title events, like real Yapcam captures (capture writes none)."""
    if not focus: name += '-nofocus'
    pkg = out_root / f'{name}.yapcam'
    if pkg.exists(): shutil.rmtree(pkg)
    seg = pkg / 'recording/seg-000'
    (seg / 'cursors').mkdir(parents=True)
    # The system arrow from a real Yapcam recording (56×80 px at 2×).
    shutil.copy(Path(__file__).with_name('assets') / 'arrow.png', seg / 'cursors/1.png')
    (seg / 'cursors.json').write_text(json.dumps({'1': {'file': 'cursors/1.png', 'hotspot': [4.5, 4], 'size_points': [28, 40]}}))

    # 1. Speech timeline: word placement with natural gaps; beats get their start/end.
    t = spec['lead']
    audio = array.array('h', bytes(0))
    words, beats = [], []
    def put(samples, at):
        start = int(at * RATE)
        if len(audio) < start: audio.extend([0] * (start - len(audio)))
        audio.extend(samples)
    for b in spec['beats']:
        tokens = b['say'].split()
        bw = []
        for tok in tokens:
            s = tts_word(spoken(tok))
            put(s, t)
            bw.append({'text': tok, 'start': t, 'end': t + len(s) / RATE})
            t += len(s) / RATE + (0.2 if tok.endswith(',') else 0.3 if tok.endswith('.') and tok is not tokens[-1] else 0.06)
        if bw: t = bw[-1]['end']
        beats.append({'start': bw[0]['start'] if bw else t, 'end': t, 'words': bw, 'first_word': len(words)})
        words += bw
        t += b['pause']
    duration = round(t * FPS) / FPS
    audio.extend([0] * (int(duration * RATE) - len(audio)))

    # 2. Actions → state changes + input events.
    events, changes, clicks = [], [], []   # changes: (time, patch)
    cursor = [720.0, 600.0]
    events.append((0.0, {'type': 'cursor', 'id': 1}))
    events.append((0.0, {'type': 'move', 'x': cursor[0], 'y': cursor[1]}))
    if focus: events.append((0.0, {'type': 'focus', 'app_bundle_id': 'com.google.Chrome', 'window_rect': [0, 0, W, H], 'window_title': spec['title']}))
    page = spec['start']['page']
    def move_to(target, at, dur=0.45):
        steps = max(2, int(dur * 60))
        for i in range(1, steps + 1):
            f = i / steps
            e = f * f * (3 - 2 * f)
            x = cursor[0] + (target[0] - cursor[0]) * e
            y = cursor[1] + (target[1] - cursor[1]) * e
            events.append((at - dur + dur * f, {'type': 'move', 'x': round(x, 1), 'y': round(y, 1)}))
        cursor[:] = target
    timed = []
    for b, beat in zip(spec['beats'], beats):
        for a in b.get('actions', []):
            if 'word' in a: at = beat['words'][a['word']]['start'] + 0.12
            elif 'at' in a: at = beat['start'] + a['at']
            else: at = beat['end'] + a['after']
            timed.append((at, a))
    timed.sort(key=lambda x: x[0])
    for at, a in timed:
        if a['do'] == 'wiggle':
            for i in range(8):
                move_to([cursor[0] + (14 if i % 2 else -14), cursor[1] + 6], at + i * 0.12, 0.12)
            continue
        if a['do'] == 'click':
            target = a.get('xy') or center(page, a['target'])
            target = [target[0] + 7, target[1] + 3] if 'target' in a else target
            move_to(target, at)
            events.append((at, {'type': 'down', 'button': 'left', 'x': target[0], 'y': target[1]}))
            events.append((at + 0.09, {'type': 'up', 'button': 'left', 'x': target[0], 'y': target[1]}))
            clicks.append({'t': round(at, 3), 'x': target[0], 'y': target[1], 'meaningful': a.get('meaningful', False),
                           'name': a.get('name') or a.get('target') or a.get('why'), 'why': a.get('why')})
            if 'target' in a:
                changes.append((at, {'pressed': a['target']}))
                changes.append((at + 0.12, {'pressed': None}))
        if a['do'] == 'type':
            text = a['text']
            for i, ch in enumerate(text):
                kt = at + i * 0.11 + (0.05 if i % 3 == 0 else 0)
                events.append((kt, {'type': 'key', 'key': ch, 'modifiers': []}))
                changes.append((kt, {'field': (a['field'], text[:i + 1])}))
            continue
        patch = {}
        if 'goto' in a:
            page = a['goto']; patch['page'] = page
            if focus: events.append((at + 0.15, {'type': 'focus', 'app_bundle_id': 'com.google.Chrome', 'window_rect': [0, 0, W, H],
                                       'window_title': 'Acme Cloud — ' + page.replace('_', ' ').title()}))
        for k in ('focus', 'select', 'toast'):
            if k in a: patch[k] = a[k]
        patch.update(a.get('set', {}))
        if patch: changes.append((at + 0.12, patch))
        if 'toast' in a: changes.append((at + 2.6, {'toast': None}))

    # 3. Render states at change times; encode with the concat demuxer (one PNG per distinct state).
    state = {'page': spec['start']['page'], 'fields': {}, 'selected': [], 'dark': False}
    changes.sort(key=lambda c: c[0])
    tmp = Path(tempfile.mkdtemp(prefix='golden-'))
    stamps = [(0.0, dict(state))]
    for at, patch in changes:
        s = json.loads(json.dumps(stamps[-1][1]))
        for k, v in patch.items():
            if k == 'field': s['fields'][v[0]] = v[1]
            elif k == 'select':
                group = v[0].split('_')[0]
                s['selected'] = [x for x in s['selected'] if not x.startswith(group + '_')] + v
            elif v is None: s.pop(k, None)
            else: s[k] = v
        frame_t = round(at * FPS) / FPS
        if stamps and abs(stamps[-1][0] - frame_t) < 1e-6: stamps[-1] = (frame_t, s)
        else: stamps.append((frame_t, s))
    lines = []
    for i, (st, s) in enumerate(stamps):
        render(s).save(tmp / f'{i:04}.png')
        end = stamps[i + 1][0] if i + 1 < len(stamps) else duration
        lines += [f"file '{tmp / f'{i:04}.png'}'", f'duration {max(1 / FPS, end - st):.6f}']
    lines.append(f"file '{tmp / f'{len(stamps) - 1:04}.png'}'")
    (tmp / 'list.txt').write_text('\n'.join(lines) + '\n')
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(tmp / 'list.txt'),
                    '-vf', f'fps={FPS}', '-t', f'{duration:.6f}', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'veryfast',
                    '-crf', '18', '-movflags', '+faststart', str(seg / 'screen.mov')], check=True)
    wav = tmp / 'mic.wav'
    with wave.open(str(wav), 'wb') as f:
        f.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        f.writeframes(audio.tobytes())
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', str(wav), '-c:a', 'aac', '-b:a', '128k', str(seg / 'mic.m4a')], check=True)
    shutil.rmtree(tmp)

    events.sort(key=lambda e: e[0])
    with open(seg / 'events.jsonl', 'w') as f:
        for at, e in events:
            f.write(json.dumps({'t': int(round(max(0, at) * 1e9)), **e}) + '\n')
    duration_ns = int(round(duration * 1e9))
    session = {
        'schema_version': 1, 'app_version': '0.1.0', 'created_at': '2026-10-17T20:00:00Z', 'status': 'complete',
        'source': {'kind': 'display', 'display_id': 1, 'display_name': 'Synthetic', 'content_rect_points': [0, 0, W, H], 'scale': 1.0,
                   'window_title': None, 'app_bundle_id': None},
        'tracks': {'screen': {'pixel_size': [W, H], 'max_fps': FPS, 'codec': 'h264', 'cursor_in_video': False}, 'camera': None,
                   'mic': {'device_name': 'Synthetic voice (say)', 'sample_rate': RATE, 'channels': 1}, 'system_audio': None},
        'segments': [{'index': 0, 'dir': 'seg-000', 'src_start_ns': 0, 'duration_ns': duration_ns, 'host_start_ns': 5_000_000_000_000,
                      'files': {'screen': 'seg-000/screen.mov', 'mic': 'seg-000/mic.m4a', 'events': 'seg-000/events.jsonl', 'cursors': 'seg-000/cursors.json'},
                      'track_start_ns': {'screen': 0, 'mic': 0}}],
    }
    (pkg / 'recording/session.json').write_text(json.dumps(session, indent=2))
    transcript = {'schema_version': 1, 'engine': 'synthetic-say-per-word', 'locale': 'en-US', 'words': [
        {'text': w['text'], 'src_start_ns': int(w['start'] * 1e9), 'src_end_ns': int(w['end'] * 1e9), 'confidence': 0.95, 'segment_index': 0, 'track': 'mic'}
        for w in words]}
    (pkg / 'recording/transcript.json').write_text(json.dumps(transcript, indent=1))

    # 4. Golden labels for the scorer.
    sentences = []
    for i, (b, beat) in enumerate(zip(spec['beats'], beats)):
        if not beat['words']: continue
        sentences.append({'beat': i, 'text': b['say'], 'from_word': beat['first_word'], 'to_word': beat['first_word'] + len(beat['words']) - 1,
                          'start_s': round(beat['start'], 3), 'end_s': round(beat['end'], 3), 'pause_after_s': b['pause'],
                          'role': b.get('role'), 'feature': b.get('feature'), 'false_start': b.get('false_start', False)})
    golden = {
        'name': name, 'duration_s': duration, 'prompts': spec['prompts'],
        'first_word_s': round(words[0]['start'], 3), 'last_word_end_s': round(words[-1]['end'], 3),
        'filler_words': [{'index': i, 'text': w['text'], 'start_s': round(w['start'], 3), 'end_s': round(w['end'], 3)}
                         for i, w in enumerate(words) if w['text'].lower().strip('.,!?') in FILLERS],
        'false_starts': [s for s in sentences if s['false_start']],
        'long_pauses': [{'after_beat': s['beat'], 'at_s': s['end_s'], 'gap_s': round(nxt['start_s'] - s['end_s'], 3)}
                        for s, nxt in zip(sentences, sentences[1:]) if nxt['start_s'] - s['end_s'] > 1.2],
        'clicks': [{**c, 'index': i} for i, c in enumerate(clicks)],
        'sentences': sentences,
        'words': [{'index': i, 'text': w['text'], 'start_s': round(w['start'], 3), 'end_s': round(w['end'], 3)} for i, w in enumerate(words)],
    }
    (pkg / 'golden.json').write_text(json.dumps(golden, indent=1))
    return golden


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=str(Path.home() / 'yapcam-spike/eval/golden'))
    ap.add_argument('--only', default='')
    ap.add_argument('--no-focus', action='store_true', help='build <name>-nofocus variants without focus events')
    args = ap.parse_args()
    out = Path(args.out).expanduser(); out.mkdir(parents=True, exist_ok=True)
    only = [s for s in args.only.split(',') if s]
    for name, spec in SCENARIOS.items():
        if only and name not in only: continue
        g = build(name, spec, out, focus=not args.no_focus)
        print(f"{name}: {g['duration_s']:.1f} s, {len(g['words'])} words, {len(g['clicks'])} clicks "
              f"({sum(c['meaningful'] for c in g['clicks'])} meaningful), {len(g['filler_words'])} fillers, {len(g['long_pauses'])} long pauses")
    (out / 'conversation.json').write_text(json.dumps(CONVERSATION, indent=1))


if __name__ == '__main__':
    sys.exit(main())
