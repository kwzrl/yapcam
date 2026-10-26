#!/usr/bin/env python3
"""Check real plist transformation and the unchanged release metadata."""
import pathlib
import plistlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
original = (root / 'Resources/Info.plist').read_bytes()
with tempfile.TemporaryDirectory() as tmp:
    plist = pathlib.Path(tmp) / 'Info.plist'
    for config in ('debug', 'release'):
        plist.write_bytes(original)
        subprocess.run([str(root / 'scripts/configure-bundle.sh'), config, str(plist)], check=True)
        data = plistlib.loads(plist.read_bytes())
        if config == 'release':
            assert plist.read_bytes() == original
            assert data['CFBundleIdentifier'] == 'mov.yapcam.Yapcam'
        else:
            assert data['CFBundleIdentifier'] == 'mov.yapcam.Yapcam.dev'
            assert data['CFBundleName'] == data['CFBundleDisplayName'] == 'Yapcam Dev'
            assert data['YapcamDevelopmentBuild'] and not data['SUEnableAutomaticChecks']
            assert data['CFBundleExecutable'] == plistlib.loads(original)['CFBundleExecutable']
print('PASS: isolated development identity; release plist byte-identical')

helper = root / 'Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater'
assert helper.is_file(), 'Vendored Sparkle Updater.app must survive a clean checkout'
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', str(helper.relative_to(root))], text=True)
assert tracked.strip(), 'Sparkle Updater must be tracked, not just present locally'
print('PASS: required Sparkle updater helper is tracked')
