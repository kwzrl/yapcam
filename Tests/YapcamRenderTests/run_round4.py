#!/usr/bin/env python3
"""Matched Round3 A/B runs and independent ten-frame export quality gate.

Media live only in a unique render-owned directory and are listed/removed on
exit. Metadata survive under Library/Logs/Yapcam/render-round4. Never launch
without Round3's desktop/ownership guards or delete another run's files.
"""
import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

sys.dont_write_bytecode = True
import run_round3 as harness

FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'


def probe(path):
    result = subprocess.check_output([FFPROBE, '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=codec_name,width,height,avg_frame_rate,nb_frames',
        '-of', 'json', str(path)], text=True, timeout=30)
    return json.loads(result)['streams'][0]


def quality(before, after):
    left = probe(before)
    right = probe(after)
    keys = ['codec_name', 'width', 'height', 'avg_frame_rate', 'nb_frames']
    if any(left.get(key) != right.get(key) for key in keys):
        raise RuntimeError('Before/after codec, size, frame rate or frame count changed')
    count = int(left['nb_frames'])
    if count < 10:
        raise RuntimeError('Ten distinct sample frames are required')
    indices = [round(i*(count-1)/9) for i in range(10)]
    selector = '+'.join(f'eq(n\\,{index})' for index in indices)
    with tempfile.TemporaryDirectory(prefix='yapcam-render-r4-psnr-') as temporary:
        try:
            stats = Path(temporary)/'psnr.txt'
            filters = (f'[0:v]select={selector},setpts=N/TB,format=gbrp[a];'
                       f'[1:v]select={selector},setpts=N/TB,format=gbrp[b];'
                       f'[a][b]psnr=stats_file={stats}')
            subprocess.run([FFMPEG, '-nostdin', '-v', 'error', '-threads', '4',
                '-i', str(before), '-threads', '4', '-i', str(after),
                '-filter_complex_threads', '1', '-filter_complex', filters,
                '-an', '-f', 'null', '-'], check=True, timeout=600)
            values = [float(value) for value in re.findall(r'psnr_avg:([0-9.inf]+)', stats.read_text())]
        finally:
            print('Cleanup own PSNR scratch:', temporary, list(Path(temporary).iterdir()), flush=True)
    if len(values) != 10 or any(value < 45 or math.isnan(value) for value in values):
        raise RuntimeError(f'Quality gate requires all ten frames PSNR >=45dB; got {values}')
    return dict(codec=left['codec_name'], width=left['width'], height=left['height'],
                frame_rate=left['avg_frame_rate'], frame_count=count, indices=indices,
                psnr_db=[value if math.isfinite(value) else 'infinite' for value in values],
                threshold_db=45, passed=True)


def compare(before, after):
    a = json.loads((before/'manifest.json').read_text())['input_fingerprints']
    b = json.loads((after/'manifest.json').read_text())['input_fingerprints']
    if not a or a != b:
        raise RuntimeError('Before/after input fingerprints differ or are absent')
    return {name: quality(before/name, after/name)
            for name in ['export-1080.mp4', 'export-2160.mp4', 'reexport.mp4']}


def self_test():
    with tempfile.TemporaryDirectory(prefix='yapcam-render-r4-quality-test-') as temporary:
        try:
            root = Path(temporary)
            first, same, changed = [root/name for name in ['first.mov', 'same.mov', 'changed.mov']]
            for path, effect in [(first, 'null'), (changed, 'negate')]:
                subprocess.run([FFMPEG, '-nostdin', '-v', 'error', '-filter_threads', '1',
                    '-f', 'lavfi', '-i', 'testsrc2=size=64x48:rate=12:duration=1',
                    '-vf', effect+',format=rgb24', '-c:v', 'qtrle', '-an', str(path)],
                    check=True, timeout=30)
            shutil.copy2(first, same)
            assert quality(first, same)['passed']
            try:
                quality(first, changed)
            except RuntimeError as error:
                assert '45dB' in str(error)
            else:
                raise AssertionError('Changed pixels must fail PSNR')
            from unittest.mock import patch
            with patch(__name__+'.probe', side_effect=[dict(codec_name='hevc'), dict(codec_name='h264')]):
                try:
                    quality(first, same)
                except RuntimeError as error:
                    assert 'codec' in str(error)
                else:
                    raise AssertionError('Changed codec must fail')
            before, after = root/'before', root/'after'
            before.mkdir(); after.mkdir()
            for folder, value in [(before, 'one'), (after, 'two')]:
                (folder/'manifest.json').write_text(json.dumps(dict(input_fingerprints={'own-fixture':value})))
            try:
                compare(before, after)
            except RuntimeError as error:
                assert 'fingerprints' in str(error)
            else:
                raise AssertionError('Different inputs cannot be compared')
            print('Round4 positive/negative ten-frame PSNR self-test PASS', flush=True)
        finally:
            print('Cleanup own quality fixtures:', temporary, list(Path(temporary).iterdir()), flush=True)


def matched_runs():
    token = str(uuid.uuid4())
    metadata = Path.home()/'Library/Logs/Yapcam/render-round4'/token
    metadata.mkdir(parents=True)
    media = Path.home()/'Movies/Yapcam/QA/render'/('round4-'+token)
    result = dict(status='blocked', baseline='fresh_readers+poll_2ms', candidate='reused_seek_reader+callbacks',
                  driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  targets=dict(scrub_p95_ms=150,export_4k_x_realtime=1.3,minimum_sample_psnr_db=45))
    try:
        if harness.LOCK.exists() or harness.apps():
            raise RuntimeError('Another session owns Yapcam; no launch')
        media.mkdir(parents=True)
        harness.build()
        run_ids = {}
        result['runs'] = run_ids
        for label, reuse, readiness in [('before', '0', 'polling'), ('after', '1', 'callback')]:
            for mode in ['scrub', 'export']:
                command = ['python3', str(harness.TOOLS/'run_round3.py'), '--skip-build',
                    '--mode', mode, '--source', 'synthetic4k', '--source-package', str(media/'input.yapcam'),
                    '--reuse-seek-reader', reuse, '--video-readiness', readiness]
                if mode == 'export':
                    command += ['--retain-exports', str(media/label)]
                log = metadata/(label+'-'+mode+'.log')
                print('Round4 stage:', label, mode, 'metadata:', log, flush=True)
                with log.open('w') as stream:
                    subprocess.run(command, cwd=harness.ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
                match = re.search(r'Round3 metadata artifacts: (.+)', log.read_text())
                if not match:
                    raise RuntimeError('Round3 run did not identify its metadata')
                run_ids[label+'-'+mode] = match.group(1)
        result['quality'] = compare(media/'before', media/'after')
        result['runs'] = run_ids
        result['status'] = 'complete'
        for name, directory in run_ids.items():
            for metric in ['scrub-random-1080.json', 'scrub-random-2160.json', 'export-2160.json']:
                path = Path(directory)/metric
                if path.exists():
                    row = json.loads(path.read_text())
                    result.setdefault(name, {})[metric] = {key:row[key] for key in ['p50_ms','p95_ms','x_realtime','sampled_peak_rss_bytes','video_stages'] if key in row}
        result['targets_met'] = dict(
            F17=all(result['after-scrub'][f'scrub-random-{height}.json']['p95_ms'] <= 150 for height in [1080, 2160]),
            F18=result['after-export']['export-2160.json']['x_realtime'] >= 1.3)
        print(json.dumps(result, indent=2), flush=True)
    except BaseException as error:
        result['reason'] = str(error)
        if 'runs' in result:
            result['status'] = 'failed'
        raise
    finally:
        (metadata/'result.json').write_text(json.dumps(result, indent=2, allow_nan=False))
        print('Round4 result:', metadata/'result.json', flush=True)
        if media.exists():
            # A later QA lock cannot keep a successful run's own media alive.
            # On failure, preserve inputs if an app might still be using them.
            if result['status'] != 'complete' and harness.LOCK.exists():
                print('App ownership still active; preserving own comparison media:', media, flush=True)
            else:
                print('Cleanup own comparison media:', media, list(media.iterdir()), flush=True)
                shutil.rmtree(media)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            matched_runs()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print('Round4 blocked:', error, file=sys.stderr)
        sys.exit(1)
