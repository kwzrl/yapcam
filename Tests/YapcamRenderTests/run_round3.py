#!/usr/bin/env python3
"""Build and launch the release Render benchmark; no media is written in the repo."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent
APP = ROOT / "build/render-round3/Yapcam.app"
LOCK = Path.home() / "Movies/Yapcam/QA/.app-lock"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, cwd=ROOT, **kwargs)


def apps():
    # NSWorkspace only, without System Events/Apple Events or permission prompts.
    script = ('ObjC.import("AppKit"); var a=$.NSWorkspace.sharedWorkspace.runningApplications; '
              'var r=[]; for(var i=0;i<a.count;i++){var p=a.objectAtIndex(i); '
              'if(ObjC.unwrap(p.bundleIdentifier)==="mov.yapcam.Yapcam") '
              'r.push({pid:p.processIdentifier,path:ObjC.unwrap(p.bundleURL.path)});} JSON.stringify({total:a.count,apps:r});')
    result = json.loads(subprocess.check_output(["/usr/bin/osascript", "-l", "JavaScript", "-e", script], text=True))
    # JXA can serialize NSNumber properties as strings on this macOS version.
    if int(result["total"]) == 0:
        raise RuntimeError("No Cocoa application session is visible; cannot verify app ownership, so no launch")
    return [dict(app, pid=int(app["pid"])) for app in result["apps"]]


def self_test():
    import unittest
    from unittest.mock import patch
    class OwnershipTests(unittest.TestCase):
        def test_unknown_session_is_not_treated_as_empty(self):
            for total in [0, "0"]:
                with self.subTest(total=total), patch("subprocess.check_output", return_value=json.dumps({"total": total, "apps": []})):
                    with self.assertRaisesRegex(RuntimeError, "cannot verify app ownership"):
                        apps()
        def test_visible_desktop_without_yapcam_is_available(self):
            with patch("subprocess.check_output", return_value='{"total":8,"apps":[]}'):
                self.assertEqual(apps(), [])
        def test_other_yapcam_instance_is_preserved(self):
            with patch("subprocess.check_output", return_value='{"total":"9","apps":[{"pid":"123","path":"other.app"}]}'):
                self.assertEqual(apps(), [{"pid":123,"path":"other.app"}])
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(OwnershipTests))
    if not result.wasSuccessful():
        raise RuntimeError("Round3 ownership guard self-test failed")


def original():
    rows = []
    for path in (Path.home() / "Movies/Yapcam").glob("Recording-*.yapcam"):
        try:
            data = json.loads((path / "recording/session.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            continue
        if data.get("status") != "complete":
            continue
        duration = max((s["src_start_ns"] + s["duration_ns"] for s in data["segments"]), default=0)
        rows.append((duration, path))
    if not rows:
        raise RuntimeError("No real Recording-*.yapcam package is available")
    return max(rows)[1]


def build():
    env = dict(os.environ, CARGO_BUILD_JOBS="4")
    # Swift's incremental cache can retain an outlined value destructor from
    # before a public struct layout change (F15). Benchmark an internally
    # consistent fresh build; --skip-build still reuses a completed signed app.
    run(["/usr/bin/swift", "package", "--disable-sandbox", "clean"], env=env)
    run([ROOT / "scripts/build-core.sh"], env=env)
    run(["/usr/bin/swift", "build", "--disable-sandbox", "-c", "release", "-j", "4", "-Xswiftc", "-enable-testing"], env=env)
    binary_dir = Path(subprocess.check_output(["/usr/bin/swift", "build", "--disable-sandbox", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
    (APP / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (APP / "Contents/Resources").mkdir(exist_ok=True)
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    objects = sorted((binary_dir / "YapcamRender.build").glob("*.swift.o")) + sorted((binary_dir / "YapcamCore.build").glob("*.swift.o"))
    if not objects:
        raise RuntimeError("Missing release Core/Render object files")
    run(["/usr/bin/swiftc", "-O", "-swift-version", "6", "-sdk", sdk, "-target", "arm64-apple-macosx15.0",
         "-parse-as-library", "-D", "YAPCAM_RENDER_ROUND3_APP", "-I", binary_dir / "Modules",
         "-I", ROOT / "Sources/CYapcamCore", "-L", ROOT / "core/target/release",
         "-module-cache-path", binary_dir / "ModuleCache",
         TOOLS / "Round3PerformanceSupport.swift", TOOLS / "Round3Runner.swift", *objects,
         "-lyapcam_core", "-o", APP / "Contents/MacOS/Yapcam"])
    for source, target in [(ROOT / "Resources/Info.plist", APP / "Contents/Info.plist"),
                           (ROOT / "Resources/AppIcon.icns", APP / "Contents/Resources/AppIcon.icns")]:
        shutil.copy2(source, target)
    run(["/usr/bin/codesign", "--force", "--sign", "Yapcam Dev Signing", "--timestamp=none", APP])
    run(["/usr/bin/codesign", "--verify", "--strict", APP])


def launch(config, log_dir):
    owner = ("render-round3 " + config["token"] + "\n").encode()
    fd = os.open(LOCK, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    config_path = log_dir / "config.json"
    work = Path(config["workDirectory"])
    process = None
    safe_cleanup = True
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(owner)
        if apps():
            raise RuntimeError("Another Yapcam instance is running; no launch")
        config_path.write_text(json.dumps(config, indent=2))
        # Never execute the app binary directly. -n avoids activating/reusing a
        # different team's instance; .app-lock remains owned until it exits.
        process = subprocess.Popen(["/usr/bin/open", "-n", "-W", str(APP), "--args", "--config", str(config_path)], cwd=ROOT)
        status = process.wait()
        if status:
            raise RuntimeError(f"LaunchServices returned {status}; executable exists={ (APP / 'Contents/MacOS/Yapcam').exists() }")
        result = json.loads((log_dir / "result.json").read_text())
        if result.get("status") != "complete":
            raise RuntimeError(result.get("reason", "Benchmark did not complete"))
    except BaseException as error:
        (log_dir / "launch-failure.json").write_text(json.dumps({"status": "blocked", "reason": str(error),
            "revision": config["revision"], "harness_sha256": config["harnessHash"], "build": "release_O_enable_testing"}, indent=2))
        raise
    finally:
        # Only a PID written by this run, still registered at OUR exact bundle
        # path, can receive a signal. Never pkill, killall or quit other instances.
        owned = log_dir / "owner.json"
        try:
            remaining = apps()
        except RuntimeError:
            remaining = []
            safe_cleanup = False  # An inaccessible desktop is not proof the app exited.
        if owned.exists():
            identity = json.loads(owned.read_text())
            matching = [app for app in remaining if app["pid"] == identity.get("pid") and Path(app["path"]).resolve() == APP.resolve()]
            if matching and identity.get("token") == config["token"]:
                os.kill(identity["pid"], signal.SIGTERM)
                for _ in range(50):
                    remaining = apps()
                    if not any(app["pid"] == identity["pid"] and Path(app["path"]).resolve() == APP.resolve() for app in remaining):
                        break
                    time.sleep(0.1)
                else:
                    safe_cleanup = False
        if process is not None and process.poll() is None:
            process.terminate()  # Only the open child started above.
            process.wait()
        if any(Path(app["path"]).resolve() == APP.resolve() for app in remaining):
            safe_cleanup = False
        if safe_cleanup:
            if work.exists():
                print("Cleanup render-owned media scratch:", work, flush=True)
                shutil.rmtree(work)
            if LOCK.exists() and LOCK.read_bytes() == owner:
                print("Cleanup render-owned app lock:", LOCK, flush=True)
                LOCK.unlink()
        else:
            print("Owned benchmark app still running; preserving its lock and scratch directory", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["probe", "smoke", "all", "preview", "scrub", "export", "soak"], default="all")
    parser.add_argument("--source", choices=["recorded", "synthetic4k", "both"], default="both")
    parser.add_argument("--real-package", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true", help="Build/sign without requiring or launching a desktop session")
    parser.add_argument("--self-test", action="store_true", help="Check ownership guards without building or launching")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.build_only:
        build()
        return
    if args.real_package:
        media_root = (Path.home() / "Movies/Yapcam").resolve()
        if not args.real_package.resolve().is_relative_to(media_root):
            raise RuntimeError("Real source must stay under ~/Movies/Yapcam")
        session = json.loads((args.real_package / "recording/session.json").read_text())
        if session.get("status") != "complete":
            raise RuntimeError("Real source is not finalized; never benchmark an active recording")
    if LOCK.exists() or apps():
        raise RuntimeError("Yapcam is owned by another session; postpone Round3")
    if not args.skip_build:
        build()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    hash_input = b"".join((TOOLS / name).read_bytes() for name in ["Round3PerformanceSupport.swift", "Round3Runner.swift", "run_round3.py"])
    fingerprint = hashlib.sha256(hash_input).hexdigest()
    sources = ["recorded", "synthetic4k"] if args.source == "both" else [args.source]
    if args.mode == "probe":
        sources = ["recorded"]  # No source is read/generated in probe mode.
    for source in sources:
        token = str(uuid.uuid4())
        logs = Path.home() / "Library/Logs/Yapcam/render-round3" / token
        logs.mkdir(parents=True)
        config = dict(mode=args.mode, source=source, revision=revision, harnessHash=fingerprint,
                      originalPackage=str(args.real_package or original()) if source == "recorded" and args.mode != "probe" else None,
                      workDirectory=str(Path.home() / "Movies/Yapcam/QA/render" / ("round3-" + token)),
                      resultsDirectory=str(logs), token=token,
                      previewSeconds=2 if args.mode == "smoke" else 30,
                      soakSeconds=0 if args.mode == "smoke" else 1200,
                      scrubSamples=4 if args.mode == "smoke" else 50,
                      syntheticSeconds=2 if args.mode == "smoke" else 120,
                      exportSeconds=2 if args.mode == "smoke" else None)
        print("Round3 metadata artifacts:", logs, flush=True)
        launch(config, logs)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("Round3 blocked:", error if isinstance(error, RuntimeError) else f"command failed with exit {error.returncode}; see diagnostics above", file=sys.stderr)
        sys.exit(1)
