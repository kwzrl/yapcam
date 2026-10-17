#!/usr/bin/env python3
"""SIGKILL a CPU fixture producer, then exercise production package recovery.

This verifies real fragmented-media recovery without a native encoder. It is NOT
an AVAssetWriter/HEVC or physical-power-loss test. Native writer has its own gate.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import time


def write_json(path, value):
    with path.open('x') as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())


def complete_fragments(data):
    offset, count, pending = 0, 0, False
    while offset + 8 <= len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        header = 8
        if size == 1:
            if offset + 16 > len(data): break
            size = struct.unpack_from('>Q', data, offset + 8)[0]
            header = 16
        if size < header or offset + size > len(data): break
        if kind == b'moof': pending = True
        if kind == b'mdat' and pending:
            count += 1
            pending = False
        offset += size
    return count


def verify(tool, root):
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe: raise RuntimeError('Installed ffmpeg/ffprobe are required for CPU fixtures')
    for trial, target in enumerate([4.43, 6.27, 8.63]):
        package = root / f'cpu-crash-{trial}.yapcam'
        segment = package / 'recording/seg-000'
        segment.mkdir(parents=True, exist_ok=False)
        write_json(package/'capture-test-fixture.json', {'synthetic': True})
        manifest = dict(schema_version=1, app_version='capture-r5-test', created_at='2026-10-17T00:00:00Z', status='recording',
                        source=dict(kind='display', display_id=1, display_name='Synthetic crash fixture',
                                    content_rect_points=[0, 0, 64, 64], scale=1),
                        tracks=dict(screen=dict(pixel_size=[64, 64], max_fps=30, codec='h264', cursor_in_video=False)),
                        segments=[dict(index=0, dir='seg-000', src_start_ns=0, duration_ns=0, host_start_ns=9000000000000,
                                       files={}, track_start_ns={'screen': 0})])
        write_json(package/'recording/session.json', manifest)
        write_json(segment/'cursors.json', {})
        with (segment/'events.jsonl').open('x') as event_file:
            event_file.write(json.dumps(dict(t=1000000000, type='marker', marker_id='retained-marker'))+'\n')
            event_file.write(json.dumps(dict(t=19000000000, type='move', x=1, y=1))+'\n')
            event_file.flush()
            os.fsync(event_file.fileno())
        movie, progress = segment/'screen.mov', package/'progress.txt'
        source = 'color=c=gray:size=64x64:rate=30' if trial == 2 else 'testsrc2=size=64x64:rate=30'
        with (package/'producer.log').open('xb') as log:
            producer = subprocess.Popen([ffmpeg, '-nostdin', '-v', 'error', '-re', '-f', 'lavfi', '-i', source,
                                         '-t', '20', '-c:v', 'libx264', '-threads', '1', '-preset', 'ultrafast',
                                         '-tune', 'zerolatency', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
                                         '-bf', '0', '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
                                         '-flush_packets', '1', '-stats_period', '0.1', '-progress', str(progress),
                                         '-f', 'mov', str(movie)], stdout=subprocess.DEVNULL, stderr=log)
            try:
                deadline, last_us = time.monotonic() + 25, 0
                while True:
                    if producer.poll() is not None: raise RuntimeError('Fixture producer exited before crash checkpoint')
                    if progress.exists():
                        for line in progress.read_text(errors='replace').splitlines():
                            if line.startswith('out_time_us=') and line[12:].isdigit(): last_us = int(line[12:])
                    data = movie.read_bytes() if movie.exists() else b''
                    if last_us >= target * 1e6 and complete_fragments(data) >= 2: break
                    if time.monotonic() >= deadline: raise TimeoutError('No real fixture fragments/progress')
                    time.sleep(0.01)
                producer.kill()  # Only this Popen-owned PID, never an app instance.
                assert producer.wait(timeout=5) == -signal.SIGKILL
            finally:
                if producer.poll() is None:
                    try: producer.kill()
                    finally: producer.wait(timeout=25)
        original = movie.read_bytes()
        subprocess.run([str(tool), '--recover-external-fixture', str(package)], check=True, timeout=15)
        recovered = json.loads((package/'recovered-check.json').read_text())
        assert recovered['complete'] == 1 and recovered['index'] == 0 and recovered['src_start_ns'] == 0
        assert recovered['screen_start_ns'] == 0
        duration = recovered['duration_ns']
        assert duration > 0 and -100000000 <= last_us * 1000 - duration <= 2100000000
        assert hashlib.sha256(original).digest() == hashlib.sha256(movie.read_bytes()).digest()
        events = [json.loads(line) for line in (segment/'events.jsonl').read_text().splitlines()]
        assert any(event.get('marker_id') == 'retained-marker' for event in events)
        assert all(event['t'] <= duration for event in events)
        subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-hwaccel', 'none', '-threads', '1', '-i', str(movie),
                        '-f', 'null', '-'], check=True, timeout=15)
        probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_packets',
                                                    '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(movie)], timeout=15))
        timestamps = [float(p['pts_time']) for p in probe['packets']]
        assert timestamps and all(a < b for a, b in zip(timestamps, timestamps[1:]))
        sync = [float(p['pts_time']) for p in probe['packets'] if 'K' in p['flags']]
        assert all(b - a <= 2.05 for a, b in zip(sync, sync[1:]))
        print(f'CAPTURE_CPU_SIGKILL_PASS trial={trial} static={trial == 2} signal=9 '
              f'fragments={complete_fragments(original)} bytes={len(original)} decoded_frames={len(timestamps)} '
              f'recovered_ns={duration} uncommitted_tail_ns={max(0, last_us * 1000 - duration)}', flush=True)


if __name__ == '__main__':
    verify(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
