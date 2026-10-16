#!/usr/bin/env python3
"""Make a new external run from existing synthetic inputs, preserving all prior outputs."""
import argparse
import json
import os
from pathlib import Path
import shutil


def prepare(source, destination):
    source, destination = source.expanduser().resolve(), destination.expanduser().resolve()
    repo = Path(__file__).resolve().parents[3]
    if destination.is_relative_to(repo) or destination.exists():
        raise ValueError('Use a new destination outside the repository')
    files = ['clean.wav', 'noisy.wav', 'noise.wav', 'screen.mov', 'ground-truth.json']
    for locale in ['de-DE', 'en-US']:
        for name in files:
            if not (source/locale/name).is_file(): raise ValueError(f'Missing input: {locale}/{name}')
        truth = json.loads((source/locale/'ground-truth.json').read_text())
        if truth['locale'] != locale: raise ValueError('Fixture locale mismatch')
    destination.mkdir(parents=True)
    try:
        for locale in ['de-DE', 'en-US']:
            (destination/locale).mkdir()
            for name in files:
                try: os.link(source/locale/name, destination/locale/name)
                except OSError: shutil.copy2(source/locale/name, destination/locale/name)
    except BaseException:
        # This destination was exclusively created above; preserve the source.
        print('Removing own incomplete rerun directory:', destination)
        shutil.rmtree(destination)
        raise
    print('Prepared fresh speech run (inputs only; prior outputs preserved):', destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path); parser.add_argument('destination', type=Path)
    args = parser.parse_args(); prepare(args.source, args.destination)
