#!/usr/bin/env python3
"""Reproduce F15's incremental layout transition, then verify a clean rebuild.

No app launches. All builds use a disposable render-owned source copy; only logs,
generated-helper disassembly and result metadata survive. Never cleans another
worktree's build directory. Requires the existing release Rust archive.
"""
import argparse
import io
import json
import os
import platform
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile
import shutil
import uuid

ROOT = Path(__file__).resolve().parents[2]
SYMBOLS = ["_$s12YapcamRender0B13ConfigurationVWOh", "_$s12YapcamRender0B13ConfigurationVACycfC"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="f8a4770")
    parser.add_argument("--candidate", default="b168140")
    args = parser.parse_args()
    output = Path.home() / "Library/Logs/Yapcam/render-f15" / str(uuid.uuid4())
    output.mkdir(parents=True)
    print("F15 metadata artifacts:", output, flush=True)
    result = {"baseline": args.baseline, "candidate": args.candidate, "build_configuration": "debug",
              "os": platform.platform(), "machine": platform.machine()}
    for name, revision in [("baseline_revision", args.baseline), ("candidate_revision", args.candidate)]:
        result[name] = subprocess.check_output(["git", "rev-parse", revision], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory(prefix="yapcam-render-f15-abi.") as directory:
        work = Path(directory)
        try:
            archive = subprocess.check_output(["git", "archive", "--format=tar", args.baseline], cwd=ROOT)
            with tarfile.open(fileobj=io.BytesIO(archive)) as source:
                source.extractall(work, filter="data")
            library = work / "core/target/release/libyapcam_core.a"
            library.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "core/target/release/libyapcam_core.a", library)

            def run(label, arguments):
                print("F15 phase:", label, flush=True)
                with (output / (label + ".log")).open("w") as log:
                    process = subprocess.Popen(arguments, cwd=work, stdout=log, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                    try:
                        code = process.wait(timeout=300)
                    except BaseException:
                        # Only our newly created process group is eligible.
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait()
                        raise
                result[label] = code
                print("F15 exit:", label, code, flush=True)
                return code

            def capture(label):
                binary = work / ".build/arm64-apple-macosx/debug"
                # Unchanged importing modules may retain the old coalesced
                # helper even when every Render object itself is up to date.
                paths = list(binary.glob("*.build/*.swift.o"))
                paths += [binary / "YapcamPackageTests.xctest/Contents/MacOS/YapcamPackageTests"]
                with (output / (label + "-helpers.txt")).open("w") as log:
                    for path in paths:
                        names = subprocess.check_output(["/usr/bin/nm", str(path)], text=True)
                        defined = [symbol for symbol in SYMBOLS if any(
                            line.split()[-1:] == [symbol] and " U " not in line for line in names.splitlines())]
                        if not defined:
                            continue
                        log.write("\nOBJECT " + path.parent.name + "/" + path.name + "\n")
                        log.write(subprocess.check_output(["/usr/bin/xcrun", "llvm-objdump", "-d",
                            "--no-show-raw-insn", "--disassemble-symbols=" + ",".join(defined), str(path)], text=True))

            swift = ["/usr/bin/swift"]
            build = swift + ["build", "--disable-sandbox", "-j", "4"]
            test = swift + ["test", "--disable-sandbox", "-j", "4", "--filter", "AudioOverlayTests"]
            for label, command in [("baseline-build", build), ("baseline-test", test)]:
                if run(label, command):
                    raise RuntimeError("Baseline must build and pass before reproducing the transition")
            capture("baseline")
            names = subprocess.check_output(["git", "diff", "--name-only", args.baseline, args.candidate,
                "--", "Sources/YapcamRender", "Tests/YapcamRenderTests"], cwd=ROOT, text=True).splitlines()
            for name in names:
                contents = subprocess.run(["git", "show", args.candidate + ":" + name], cwd=ROOT, capture_output=True)
                path = work / name
                if contents.returncode:
                    path.unlink(missing_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(contents.stdout)
            if run("incremental-build", build):
                raise RuntimeError("Candidate must compile before testing runtime layout")
            run("incremental-test", test)
            capture("incremental")
            failed = (output / "incremental-test.log").read_text()
            if result["incremental-test"] and "unexpected signal code 11" not in failed:
                raise RuntimeError("Incremental test failed for a different reason; inspect its log")
            result["sigsegv_reproduced"] = "unexpected signal code 11" in failed
            if run("clean", swift + ["package", "--disable-sandbox", "clean"]) or run("clean-test", test):
                raise RuntimeError("Identical source must pass after the clean rebuild")
            capture("clean")
            result["clean_rebuild_passed"] = True
        finally:
            (output / "result.json").write_text(json.dumps(result, indent=2))
            print("Cleanup render-owned F15 copy:", work, [p.name for p in work.iterdir()], flush=True)


if __name__ == "__main__":
    main()
