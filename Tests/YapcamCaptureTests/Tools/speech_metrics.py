#!/usr/bin/env python3
"""Measure fixture outputs without hiding recognition or DSP failures.
WER ignores case/punctuation only. Output SI-SDR is a gain-fitted residual metric,
not proof of denoising: it includes speech distortion. Sentence timing uses only
matched first/last words, never invents interior word ground truth.
"""
import argparse
import array
import json
import math
from pathlib import Path
import re
import statistics
import subprocess


def words(text):
    return re.findall(r"[^\W_]+(?:['’][^\W_]+)*", text.casefold(), re.UNICODE)


def alignment(reference, actual):
    """Levenshtein alignment; operations preserve indices for boundary scoring."""
    rows = [[0] * (len(actual)+1) for _ in range(len(reference)+1)]
    for i in range(len(reference)+1): rows[i][0] = i
    for j in range(len(actual)+1): rows[0][j] = j
    for i, a in enumerate(reference, 1):
        for j, b in enumerate(actual, 1):
            rows[i][j] = min(rows[i-1][j]+1, rows[i][j-1]+1, rows[i-1][j-1]+(a != b))
    i, j = len(reference), len(actual)
    result = []
    while i or j:
        if i and j and rows[i][j] == rows[i-1][j-1]+(reference[i-1] != actual[j-1]):
            result.append(('match' if reference[i-1] == actual[j-1] else 'substitution', i-1, j-1)); i-=1; j-=1
        elif i and rows[i][j] == rows[i-1][j]+1:
            result.append(('deletion', i-1, None)); i-=1
        else:
            result.append(('insertion', None, j-1)); j-=1
    return list(reversed(result))


def transcript_metrics(truth, transcript):
    reference = words(truth['reference_text'])
    actual, owners = [], []
    for word in transcript['words']:
        tokens = words(word['text']); actual.extend(tokens); owners.extend([word] * len(tokens))
    aligned = alignment(reference, actual)
    counts = {op: sum(a[0] == op for a in aligned) for op in ['substitution', 'deletion', 'insertion']}
    matched = {r: a for op, r, a in aligned if op == 'match'}
    offsets, reference_index = [], 0
    for sentence in truth['sentences']:
        end = reference_index + len(words(sentence['text'])) - 1
        for index, key, bound in [(reference_index, 'src_start_ns', 'start_ns'), (end, 'src_end_ns', 'end_ns')]:
            if index in matched: offsets.append(abs(owners[matched[index]][key] - sentence[bound]) / 1e6)
        reference_index = end+1
    fillers = {'um', 'uh', 'uhm', 'umm', 'er', 'erm', 'ah', 'hm', 'hmm', 'mm', 'mhm', 'äh', 'ähm', 'öh', 'eh'}
    return dict(expected_fillers=sum(w in fillers for w in reference),
                recognized_fillers=sum(w in fillers for w in actual),
                correctly_aligned_fillers=sum(reference[r] in fillers for op, r, a in aligned if op == 'match'),
                reference_words=len(reference), recognized_words=len(actual), **counts,
                wer=sum(counts.values())/len(reference), scored_sentence_boundaries=len(offsets),
                sentence_boundary_median_ms=statistics.median(offsets) if offsets else None,
                sentence_boundary_max_ms=max(offsets) if offsets else None,
                timing_limit='10 ms sentence activity bounds; no interior-word timing ground truth')


def decode(path):
    result = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-f', 'f32le', '-ar', '48000', '-ac', '1', '-'],
                            capture_output=True, check=True, timeout=90)
    pcm = array.array('f', result.stdout)
    import sys
    if sys.byteorder != 'little': pcm.byteswap()
    if not pcm or not all(math.isfinite(v) for v in pcm): raise ValueError('Empty/nonfinite audio')
    return pcm


def residual_metrics(clean, output):
    if len(clean) != len(output): raise ValueError('Duration changed; no implicit trimming/alignment')
    energy = sum(v*v for v in clean)
    if energy <= 0: raise ValueError('Reference is silent')
    gain = sum(a*b for a, b in zip(clean, output))/energy
    residual = sum((b-gain*a)**2 for a, b in zip(clean, output))
    signal = gain*gain*energy
    return dict(reference_gain=gain, si_sdr_db=10*math.log10(signal/residual) if signal > 0 and residual > 0 else None,
                peak_dbfs=20*math.log10(max(abs(v) for v in output)) if any(output) else None,
                clipped_samples=sum(abs(v) >= 1 for v in output), frames=len(output))


def lufs(path):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-i', str(path), '-af', 'loudnorm=print_format=json', '-f', 'null', '-'],
                            capture_output=True, text=True, check=True, timeout=90)
    body = result.stderr[result.stderr.rfind('{'):]
    value = float(json.loads(body)['input_i'])
    return value if math.isfinite(value) else None


def dsp_metrics(directory, output):
    clean = decode(directory/'clean.wav'); noisy = decode(directory/'noisy.wav'); noise = decode(directory/'noise.wav')
    if len(noisy) != len(clean) or len(noise) != len(clean): raise ValueError('Input stems have different durations')
    result = residual_metrics(clean, decode(output))
    result['input_snr_db'] = 10*math.log10(sum(v*v for v in clean)/sum(v*v for v in noise))
    result['input_si_sdr_db'] = residual_metrics(clean, noisy)['si_sdr_db']
    result['input_lufs'] = lufs(directory/'noisy.wav'); result['output_lufs'] = lufs(output)
    result['listening'] = 'pending Lead: pumping and speech quality cannot be certified by these metrics'
    return result


def main(root):
    report = {}
    for locale in ['de-DE', 'en-US']:
        directory = root/locale
        truth = json.loads((directory/'ground-truth.json').read_text())
        outcomes = json.loads((directory/'outcomes.json').read_text())
        result = dict(outcomes=outcomes)
        for variant in ['clean', 'noisy']:
            transcript = directory/f'{variant}-transcript.json'
            if transcript.exists():
                try: result[variant] = transcript_metrics(truth, json.loads(transcript.read_text()))
                except (ValueError, KeyError) as error: result[variant] = dict(measurement_error=str(error))
        for variant in ['dsp', 'isolated']:
            output = directory/f'{variant}.caf'
            if output.exists():
                try: result[variant] = dsp_metrics(directory, output)
                except (ValueError, subprocess.SubprocessError) as error: result[variant] = dict(measurement_error=str(error))
        report[locale] = result
    (root/'metrics.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False)+'\n')
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('fixtures', type=Path)
    main(parser.parse_args().fixtures.expanduser())
