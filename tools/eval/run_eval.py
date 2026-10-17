#!/usr/bin/env python3
"""Run one agent-eval scenario end to end and score it.

Copies a golden package (tools/eval/make_golden.py) to a temp dir, launches the built app on it with its own MCP
port/token (argument domain, nothing written to preferences), runs headless Claude Code exactly like the in-app
chat runner (AgentPromptRunner: chat system prompt from core/agent-docs/chat.md, --model opus, strict MCP config,
only the resource tools besides MCP), records the stream, reads the project before/after, runs `check` and a
`capture` contact sheet after, quits the app and scores the result against golden.json (RUBRIC.md).

Usage:
  run_eval.py tighten|walkthrough|changelog|nice|conversation [--runs-dir DIR] [--app build/Yapcam.app]
              [--port 7784] [--budget 1.5] [--model opus] [--tag x]
  run_eval.py --score RUN_DIR         re-score a finished run (no app, no Claude)

Never touches ~/Movies/Yapcam or port 7777. Costs real money: one Claude run per prompt.
"""
import argparse
import base64
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GOLDEN = Path.home() / 'yapcam-spike/eval/golden'
RUNS = Path.home() / '.delegate/2026-10-17-agentic-quality/ae-eval-artifacts'
MUTATING_READS = {'moments', 'check', 'read_project', 'project_summary', 'read_transcript', 'read_events', 'list_documents',
                  'capture', 'grab', 'filmstrip', 'waveform', 'seek', 'select', 'transcription_status', 'save'}


# -------------------------------------------------------------------------------------------------- MCP client
class MCP:
    def __init__(self, port, token, package):
        self.url = f'http://127.0.0.1:{port}/mcp'
        self.headers = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
                        'MCP-Protocol-Version': '2025-06-18', 'Authorization': f'Bearer {token}', 'X-Yapcam-Project': str(package)}
        self.session, self.counter = None, 0

    def rpc(self, method, params=None, timeout=300):
        self.counter += 1
        body = {'jsonrpc': '2.0', 'id': self.counter, 'method': method, **({'params': params} if params is not None else {})}
        headers = dict(self.headers, **({'Mcp-Session-Id': self.session} if self.session else {}))
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers, method='POST')
        with urllib.request.urlopen(req, timeout=timeout) as r:
            self.session = r.headers.get('Mcp-Session-Id') or self.session
            data = json.loads(r.read())
        if 'error' in data: raise RuntimeError(f'{method}: {data["error"]}')
        return data['result']

    def initialize(self):
        return self.rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'yapcam-eval', 'version': '1'}})

    def call(self, name, args=None, raw=False):
        result = self.rpc('tools/call', {'name': name, 'arguments': args or {}})
        if raw: return result
        if result.get('isError'): raise RuntimeError(f'{name}: {result.get("content")}')
        return result.get('structuredContent', result)


def save_images(result, out, stem):
    paths = []
    for i, c in enumerate(result.get('content', [])):
        if c.get('type') == 'image':
            p = out / f'{stem}-{i}.png'
            p.write_bytes(base64.b64decode(c['data'])); paths.append(p.name)
    return paths


# --------------------------------------------------------------------------------------------------- the app
def port_busy(port):
    return subprocess.run(['lsof', f'-iTCP:{port}', '-sTCP:LISTEN', '-t'], capture_output=True, text=True).stdout.strip()


def launch(app, package, port, token):
    for _ in range(120):
        if not port_busy(port): break
        time.sleep(5)
    else: raise SystemExit(f'port {port} stays busy')
    subprocess.run(['open', '-n', '-g', '-a', str(Path(app).resolve()), str(package), '--args', '-agent.mcp.port', str(port),
                    '-agent.mcp.token', token, '-ApplePersistenceIgnoreState', 'YES'], check=True)
    for _ in range(120):
        pid = port_busy(port)
        if pid: return int(pid.split()[0])
        time.sleep(0.5)
    raise SystemExit('app did not start its MCP server')


def quit_app(pid):
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: return
    for _ in range(40):
        try: os.kill(pid, 0)
        except ProcessLookupError: return
        time.sleep(0.25)
    os.kill(pid, signal.SIGKILL)


# ---------------------------------------------------------------------------------------------- Claude Code
def system_prompt(package):
    template = (REPO / 'core/agent-docs/chat.md').read_text()
    return (template.replace('{document}', package.stem)
            + f'\nThis chat is bound to that document ({package}); you do not need to pass `project`.')


def run_claude(prompt, package, port, token, out, stem, model, budget, resume=None):
    """Same arguments as ClaudeProcess.run in AgentPromptRunner.swift (plus a spend cap)."""
    config = out / 'mcp.json'
    config.write_text(json.dumps({'mcpServers': {'yapcam': {'type': 'http', 'url': f'http://127.0.0.1:{port}/mcp', 'headers': {
        'Authorization': f'Bearer {token}', 'X-Yapcam-Project': str(package)}}}}))
    workdir = out / 'claude-cwd'; workdir.mkdir(exist_ok=True)
    args = ['claude', '-p', prompt, '--output-format', 'stream-json', '--verbose', '--mcp-config', str(config),
            '--strict-mcp-config', '--allowedTools', 'mcp__yapcam__*,ListMcpResourcesTool,ReadMcpResourceTool',
            '--tools', 'ListMcpResourcesTool,ReadMcpResourceTool', '--permission-mode', 'acceptEdits',
            '--system-prompt', system_prompt(package), '--max-budget-usd', str(budget)]
    if resume: args += ['--resume', resume]
    if model: args += ['--model', model]
    started = time.time()
    stream = out / f'{stem}.stream.jsonl'
    with open(stream, 'w') as f:
        subprocess.run(args, cwd=workdir, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=1800)
    config.unlink()
    return summarize_stream(stream, time.time() - started)


def summarize_stream(stream, wall=None):
    calls, result, session = [], {}, None
    for line in stream.read_text().splitlines():
        try: e = json.loads(line)
        except json.JSONDecodeError: continue
        session = e.get('session_id') or session
        if e.get('type') == 'assistant':
            for c in e['message'].get('content', []):
                if c.get('type') == 'tool_use':
                    calls.append({'name': c['name'].split('__')[-1], 'input': c.get('input', {})})
        if e.get('type') == 'user':
            for c in (e.get('message', {}).get('content') or []):
                if isinstance(c, dict) and c.get('type') == 'tool_result' and c.get('is_error') and calls:
                    text = c.get('content')
                    text = text if isinstance(text, str) else ' '.join(x.get('text', '') for x in text or [] if isinstance(x, dict))
                    calls[-1]['error'] = text[:300] or True
        if e.get('type') == 'result': result = e
    return {'session_id': session, 'calls': calls, 'answer': result.get('result', ''), 'is_error': result.get('is_error'),
            'cost_usd': result.get('total_cost_usd'), 'turns': result.get('num_turns'), 'duration_s': (result.get('duration_ms') or 0) / 1000 or wall,
            'wall_s': wall}


# --------------------------------------------------------------------------------------------------- scoring
def to_tl(clips, src_s):
    """Source seconds → timeline seconds, or None when the instant is cut."""
    ns, t = src_s * 1e9, 0.0
    for c in clips:
        if c['src_start_ns'] <= ns < c['src_end_ns']:
            return (t + (ns - c['src_start_ns']) / c.get('speed', 1)) / 1e9
        t += (c['src_end_ns'] - c['src_start_ns']) / c.get('speed', 1)
    return None


def kept_fraction(clips, a, b):
    a, b = a * 1e9, b * 1e9
    kept = sum(max(0, min(b, c['src_end_ns']) - max(a, c['src_start_ns'])) for c in clips)
    return kept / max(1, b - a)


def score(run_dir):
    run_dir = Path(run_dir)
    meta = json.loads((run_dir / 'run.json').read_text())
    golden = json.loads((run_dir / 'golden.json').read_text())
    after = json.loads((run_dir / 'after.project.json').read_text())
    check = json.loads((run_dir / 'after.check.json').read_text())
    clips = after['timeline']['clips']
    duration = sum((c['src_end_ns'] - c['src_start_ns']) / c.get('speed', 1) for c in clips) / 1e9
    words = golden['words']
    kept = [(w, kept_fraction(clips, w['start_s'], w['end_s'])) for w in words]
    partial = [w['text'] for w, k in kept if 0.05 < k < 0.95]
    kept_words = [w for w, k in kept if k >= 0.95]
    tl_words = [(w, to_tl(clips, w['start_s']), to_tl(clips, w['end_s'] - 1e-4)) for w in kept_words]
    gaps = [b[1] - a[2] for a, b in zip(tl_words, tl_words[1:]) if a[2] is not None and b[1] is not None]
    lead = tl_words[0][1] if tl_words else None
    tail = duration - tl_words[-1][2] if tl_words else None
    fillers = golden['filler_words']
    fillers_left = [f['text'] for f in fillers if kept_fraction(clips, f['start_s'], f['end_s']) > 0.5]
    false_left = [s['text'] for s in golden['false_starts'] if kept_fraction(clips, s['start_s'], s['end_s']) > 0.5]

    zooms = [z for z in after.get('zooms', []) if z.get('enabled', True) and z.get('mode') == 'manual']
    clicks = [{**c, 'tl': to_tl(clips, c['t'])} for c in golden['clicks']]
    zoom_rows, overlaps = [], 0
    zs = sorted(zooms, key=lambda z: z['tl_start_ns'])
    for a, b in zip(zs, zs[1:]):
        if b['tl_start_ns'] < a['tl_end_ns']: overlaps += 1
    for z in zs:
        s, e = z['tl_start_ns'] / 1e9, z['tl_end_ns'] / 1e9
        inside = [c for c in clicks if c['tl'] is not None and s <= c['tl'] <= e]
        zoom_rows.append({'start_s': round(s, 2), 'end_s': round(e, 2), 'len_s': round(e - s, 2), 'scale': z.get('scale'),
                          'clicks': [c['name'] for c in inside], 'meaningful': any(c['meaningful'] for c in inside),
                          'accidental_only': bool(inside) and not any(c['meaningful'] for c in inside), 'past_end': e > duration + 1e-3})
    meaningful_kept = [c for c in clicks if c['meaningful'] and c['tl'] is not None]
    covered = [c['name'] for c in meaningful_kept if any(z['start_s'] <= c['tl'] <= z['end_s'] for z in zoom_rows)]

    # Verification: a capture/filmstrip after the last mutating call of the last prompt.
    verified = []
    for p in meta['prompts']:
        calls = p['calls']
        mut = [i for i, c in enumerate(calls) if c['name'] not in MUTATING_READS and not c['name'].endswith('McpResourceTool')]
        last = mut[-1] if mut else -1
        verified.append(any(c['name'] in ('capture', 'filmstrip') for c in calls[last + 1:]) if mut else None)
    sev = [i.get('severity') for i in check.get('issues', [])]
    s = {
        'duration_s': round(duration, 2), 'source_duration_s': golden['duration_s'],
        'check_errors': sev.count('error'), 'check_warnings': sev.count('warning'),
        'check_kinds': sorted({i.get('kind') for i in check.get('issues', [])}),
        'cut_inside_words': partial,
        'lead_s': round(lead, 2) if lead is not None else None,
        'max_pause_s': round(max(gaps), 2) if gaps else None, 'pauses_over_1_2': sum(g > 1.2 for g in gaps),
        'tail_s': round(tail, 2) if tail is not None else None,
        'fillers_total': len(fillers), 'fillers_left': fillers_left, 'false_starts_left': false_left,
        'words_kept': f'{len(kept_words)}/{len(words)}',
        'zooms': zoom_rows, 'zoom_overlaps': overlaps, 'zooms_on_accidental': sum(z['accidental_only'] for z in zoom_rows),
        'zooms_on_nothing': sum(not z['clicks'] for z in zoom_rows),
        'zooms_past_end': sum(z['past_end'] for z in zoom_rows),
        'zoom_len_out_of_1_8': sum(not (1 <= z['len_s'] <= 8) for z in zoom_rows),
        'meaningful_clicks_zoomed': f'{len(covered)}/{len(meaningful_kept)}',
        'verified_with_capture': verified,
        'cost_usd': round(sum(p.get('cost_usd') or 0 for p in meta['prompts']), 3),
        'turns': [p.get('turns') for p in meta['prompts']],
        'time_s': [round(p.get('duration_s') or 0) for p in meta['prompts']],
        'answer_lines': [len([l for l in (p.get('answer') or '').splitlines() if l.strip()]) for p in meta['prompts']],
        'answer_words': [len((p.get('answer') or '').split()) for p in meta['prompts']],
        'tool_calls': [len(p['calls']) for p in meta['prompts']],
        'tool_errors': [sum(bool(c.get('error')) for c in p['calls']) for p in meta['prompts']],
        'vision_hint_errors': [sum('Vision hint' in str(c.get('error', '')) for c in p['calls']) for p in meta['prompts']],
        'after_errors': meta.get('after_errors', {}),
    }
    roles = {}
    for sen in golden['sentences']:
        if sen.get('role'):
            roles.setdefault(sen['role'], []).append(kept_fraction(clips, sen['start_s'], sen['end_s']) > 0.9)
    if roles: s['sentences_kept_by_role'] = {r: f'{sum(v)}/{len(v)}' for r, v in roles.items()}
    (run_dir / 'score.json').write_text(json.dumps(s, indent=1))
    return s


# ------------------------------------------------------------------------------------------------------- main
def capture_times(project, duration):
    times = {0.0, max(0.0, duration - 0.05)}
    t = 0.0
    for c in project['timeline']['clips'][:-1]:
        t += (c['src_end_ns'] - c['src_start_ns']) / c.get('speed', 1) / 1e9
        times.update({max(0, t - 0.2), min(duration, t + 0.2)})
    for z in project.get('zooms', []):
        times.add(min(duration, (z['tl_start_ns'] + z['tl_end_ns']) / 2e9))
    for item in project.get('canvas', {}).get('annotations', []) + project.get('canvas', {}).get('highlights', []):
        if 'tl_start_ns' in item: times.add(min(duration, (item['tl_start_ns'] + item['tl_end_ns']) / 2e9))
    times = sorted(round(x, 2) for x in times)
    if len(times) > 12:  # keep first/last and an even spread
        step = (len(times) - 1) / 11
        times = sorted({times[round(i * step)] for i in range(12)})
    return times


def recapture(run_dir, times, app, port):
    golden = json.loads((run_dir / 'golden.json').read_text())
    work = Path('/tmp').resolve() / f'yapcam-eval-recapture-{time.strftime("%H%M%S")}'
    package = work / f'{golden["name"]}.yapcam'
    shutil.copytree(GOLDEN / f'{golden["name"]}.yapcam', package)
    (package / 'project.json').write_text((run_dir / 'after.project.json').read_text())
    token = secrets.token_hex(32)
    pid = launch(app, package, port, token)
    try:
        mcp = MCP(port, token, package); mcp.initialize()
        for _ in range(60):
            try: mcp.call('project_summary'); break
            except Exception: time.sleep(0.5)
        print(save_images(mcp.call('capture', {'times': times}, raw=True), run_dir, f'recapture-{time.strftime("%H%M%S")}'))
    finally:
        quit_app(pid); shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('scenario', nargs='?')
    ap.add_argument('--score')
    ap.add_argument('--runs-dir', default=str(RUNS))
    ap.add_argument('--app', default=str(REPO / 'build/Yapcam.app'))
    ap.add_argument('--port', type=int, default=7784)
    ap.add_argument('--budget', type=float, default=1.5, help='USD cap per prompt (--max-budget-usd)')
    ap.add_argument('--model', default='opus')
    ap.add_argument('--tag', default='')
    ap.add_argument('--recapture', help='RUN_DIR: reopen its after.project.json and capture --times (no Claude)')
    ap.add_argument('--times', default='', help='comma-separated seconds for --recapture')
    ap.add_argument('--dry', action='store_true', help='plumbing only: no Claude call')
    a = ap.parse_args()
    if a.score:
        print(json.dumps(score(a.score), indent=1)); return
    if a.port == 7777: raise SystemExit('7777 belongs to the user app')
    if a.recapture:
        recapture(Path(a.recapture), [float(t) for t in a.times.split(',')], a.app, a.port); return

    if a.scenario == 'conversation':
        conv = json.loads((GOLDEN / 'conversation.json').read_text())
        source, prompts = GOLDEN / f'{conv["package"]}.yapcam', conv['prompts']
    else:
        source = GOLDEN / f'{a.scenario}.yapcam'
        prompts = json.loads((source / 'golden.json').read_text())['prompts']
    if a.dry: prompts = []
    stamp = time.strftime('%H%M%S')
    out = Path(a.runs_dir) / f'{a.scenario}{"-" + a.tag if a.tag else ""}-{stamp}'
    out.mkdir(parents=True)
    work = Path('/tmp').resolve() / f'yapcam-eval-{a.scenario}-{stamp}'
    package = work / f'{a.scenario}.yapcam'
    shutil.copytree(source, package)
    shutil.copy(source / 'golden.json', out / 'golden.json')
    token = secrets.token_hex(32)
    pid = launch(a.app, package, a.port, token)
    meta = {'scenario': a.scenario, 'package': str(package), 'model': a.model, 'app_pid': pid, 'prompts': []}
    try:
        mcp = MCP(a.port, token, package)
        mcp.initialize()
        for _ in range(60):  # the document may still be opening
            try: mcp.call('project_summary'); break
            except Exception: time.sleep(0.5)
        (out / 'before.project.json').write_text(json.dumps(mcp.call('read_project'), indent=1))
        (out / 'before.moments.json').write_text(json.dumps(mcp.call('moments'), indent=1))
        (out / 'before.check.json').write_text(json.dumps(mcp.call('check'), indent=1))
        session = None
        for i, prompt in enumerate(prompts):
            print(f'[{a.scenario}] prompt {i + 1}: {prompt}', flush=True)
            r = run_claude(prompt, package, a.port, token, out, f'prompt{i + 1}', a.model, a.budget, resume=session)
            session = r['session_id'] or session
            r['prompt'] = prompt
            meta['prompts'].append(r)
            (out / f'after{i + 1}.project.json').write_text(json.dumps(mcp.call('read_project'), indent=1))
            print(f'  -> {r["turns"]} turns, ${r["cost_usd"]}, {r["duration_s"]:.0f}s, {len(r["calls"])} calls: {r["answer"][:300]!r}', flush=True)
        project = mcp.call('read_project')
        (out / 'after.project.json').write_text(json.dumps(project, indent=1))
        # The app enriches moments/check with pixel hints; record a failure of that path, then read without hints.
        meta['after_errors'] = {}
        for name in ('moments', 'check'):
            try: result = mcp.call(name)
            except RuntimeError as e:
                meta['after_errors'][name] = str(e)
                result = mcp.call(name, {'static_cuts_s': [], 'visual_view_changes_s': [], **({'visual_view_changes': []} if name == 'check' else {})})
            (out / f'after.{name}.json').write_text(json.dumps(result, indent=1))
        duration = mcp.call('project_summary')['duration_ns'] / 1e9
        result = mcp.call('capture', {'times': capture_times(project, duration)}, raw=True)
        meta['after_capture'] = save_images(result, out, 'after-capture')
        result = mcp.call('filmstrip', {'count': 12}, raw=True)
        meta['after_filmstrip'] = save_images(result, out, 'after-filmstrip')
    finally:
        (out / 'run.json').write_text(json.dumps(meta, indent=1))
        quit_app(pid)
        # Keep the edited package (small, media included) so a run can be reopened or recaptured.
        shutil.copytree(package, out / 'edited.yapcam', ignore=shutil.ignore_patterns('autosave'))
        shutil.rmtree(work, ignore_errors=True)
    print(json.dumps(score(out), indent=1))
    print(out)


if __name__ == '__main__':
    sys.exit(main())
