#!/usr/bin/env python3
"""Generate public synthetic speech + seeded 10 dB noise outside the repository.
Sentence bounds are measured from 10 ms PCM windows at -45 dBFS; they are NOT
word-level forced alignments. All number spellings are intentional WER references.
"""
import argparse
import array
import json
import math
from pathlib import Path
import random
import subprocess
import tempfile
import wave

SCRIPTS = {
    'en-US': ('Samantha', [
        'Hello, my name is Clara, and today we are testing a local recording workflow.',
        'Um, the meeting with David starts at nine thirty on Monday morning.',
        'Please bring seven blue folders and twenty three copies of the project plan.',
        'Our colleague Maria will explain how the new camera settings affect the picture.',
        'We will record the first example slowly, then compare it with the second example.',
        'Uh, I think the train to Brighton leaves from platform twelve this afternoon.',
        'The price is forty two euros, including delivery, but excluding the optional cover.',
        'After this short pause, listen carefully to the words at the beginning of the sentence.',
        'Um, Peter said that a clear explanation matters more than a complicated technical name.',
        'We can delete a repeated word without changing the order of the remaining ideas.',
        'Before we finish, please check the sound level and save the original audio file.',
        'Thank you for listening, and remember that this example never used a microphone.',
    ]),
    'de-DE': ('Anna', [
        'Hallo, ich heiße Clara und heute testen wir einen lokalen Ablauf für Bildschirmaufnahmen.',
        'Äh, das Treffen mit David beginnt am Montagmorgen um halb zehn im Büro.',
        'Bitte bring sieben blaue Ordner und dreiundzwanzig Kopien von unserem neuen Projektplan mit.',
        'Unsere Kollegin Maria erklärt gleich, wie die neuen Kameraeinstellungen das fertige Bild verändern.',
        'Wir sprechen das erste Beispiel langsam und vergleichen es danach mit dem zweiten Beispiel.',
        'Ähm, ich glaube, der Zug nach Hamburg fährt heute Nachmittag von Gleis zwölf ab.',
        'Der Preis beträgt zweiundvierzig Euro mit Lieferung, aber ohne die zusätzliche blaue Schutzhülle.',
        'Nach dieser kurzen Pause achten wir besonders auf den Anfang des nächsten gesprochenen Satzes.',
        'Äh, Peter sagt, eine klare Erklärung ist oft wichtiger als ein sehr komplizierter Fachbegriff.',
        'Wir können ein wiederholtes Wort löschen und dabei die Reihenfolge der übrigen Gedanken erhalten.',
        'Bevor wir fertig sind, prüfen wir den Tonpegel und speichern die ursprüngliche Audiodatei ab.',
        'Vielen Dank fürs Zuhören und bitte beachten, für dieses Beispiel wurde kein Mikrofon verwendet.',
    ]),
}
RATE = 48000
PAUSES = [.3, .7, 1.2, 2., .5, 1., 1.8, .3, 1.5, .8, 1.1, 2.]


def run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, timeout=90)


def write_wav(path, samples):
    with wave.open(str(path), 'wb') as f:
        f.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        data = array.array('h', (round(max(-1, min(1, v)) * 32767) for v in samples))
        import sys
        if sys.byteorder != 'little': data.byteswap()
        f.writeframes(data.tobytes())


def generate(root):
    root.mkdir(parents=True, exist_ok=True)
    for locale, (voice, sentences) in SCRIPTS.items():
        target = root / locale
        target.mkdir(exist_ok=True)
        if (target / 'ground-truth.json').exists():
            raise RuntimeError(f'Refusing to replace existing fixtures in {target}')
        samples = array.array('f', [0.] * RATE)
        bounds = []
        # Context manager cleans only this generator's temporary files on every exit.
        with tempfile.TemporaryDirectory(prefix='yapcam-capture-round3-say-') as tmp:
            for index, text in enumerate(sentences):
                aiff, wav = Path(tmp) / 'sentence.aiff', Path(tmp) / 'sentence.wav'
                run(['/usr/bin/say', '-v', voice, '-r', '155', '-o', str(aiff), text])
                run(['ffmpeg', '-v', 'error', '-y', '-i', str(aiff), '-ac', '1', '-ar', str(RATE), str(wav)])
                with wave.open(str(wav), 'rb') as f:
                    pcm = array.array('h', f.readframes(f.getnframes()))
                import sys
                if sys.byteorder != 'little': pcm.byteswap()
                floats = array.array('f', (v / 32768 for v in pcm))
                active = [i for i in range(0, len(floats), 480)
                          if sum(v*v for v in floats[i:i+480]) / len(floats[i:i+480]) > 10 ** (-45/10)]
                if not active: raise RuntimeError(f'No synthesized speech: {locale}, {index}')
                first, last = active[0], min(len(floats), active[-1] + 480)
                start = len(samples)
                samples.extend(floats[first:last])
                end = len(samples)
                samples.extend([0.] * round(PAUSES[index] * RATE))
                bounds.append(dict(text=text, start_ns=round(start/RATE*1e9), end_ns=round(end/RATE*1e9),
                                   following_pause_ns=round(PAUSES[index]*1e9)))
        duration = len(samples) / RATE
        if not 60 <= duration <= 90: raise RuntimeError(f'{locale}: {duration:.2f}s outside 60–90s')
        # Speech is peak-normalized once, then white noise is set using whole-file
        # energy. The clean/noise stems give exact input SNR, including pauses.
        gain = .65 / max(abs(v) for v in samples)
        clean = array.array('f', (v * gain for v in samples))
        rng = random.Random(594150)
        noise = array.array('f', (rng.uniform(-1, 1) for _ in clean))
        scale = math.sqrt(sum(v*v for v in clean) / (10 * sum(v*v for v in noise)))
        noise = array.array('f', (v * scale for v in noise))
        mixed = array.array('f', (a+b for a, b in zip(clean, noise)))
        if max(abs(v) for v in mixed) >= 1: raise RuntimeError('Mixture clips')
        for name, data in [('clean', clean), ('noise', noise), ('noisy', mixed)]:
            write_wav(target / f'{name}.wav', data)
        run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=1',
             '-t', str(duration), '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(target/'screen.mov')])
        truth = dict(locale=locale, voice=voice, rate=RATE, duration_ns=round(duration*1e9),
                     seed=594150, snr_db=10, timing_reference='sentence PCM activity bounds, 10 ms at -45 dBFS',
                     sentences=bounds, reference_text=' '.join(sentences))
        (target / 'ground-truth.json').write_text(json.dumps(truth, ensure_ascii=False, indent=2)+'\n')
        print(f'{locale}: {duration:.3f}s, {len(truth["reference_text"].split())} words, input SNR 10.000 dB', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New directory outside the repository')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    if args.output.expanduser().resolve().is_relative_to(repo): parser.error('Media must be outside the repository')
    generate(args.output.expanduser().resolve())
