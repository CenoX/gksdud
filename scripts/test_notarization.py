"""Exercise build.sh's publication gates without compiling or contacting Apple."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SHIM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["TEST_ROOT"])
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([command] + args) + "\n")
failure = os.environ.get("TEST_FAILURE", "")
if command == "mktemp":
    stage = root / "stage"
    stage.mkdir()
    print(stage)
elif command == "swiftc" or command == "lipo":
    flag = "-o" if command == "swiftc" else "-output"
    target = pathlib.Path(args[args.index(flag) + 1])
    target.write_text("#!/bin/sh\nexit 0\n")
    target.chmod(0o755)
elif command == "ditto":
    pathlib.Path(args[-1]).write_bytes(b"mock archive")
elif command == "xcrun" and args[:2] == ["notarytool", "history"]:
    if failure == "credentials":
        sys.exit(1)
    print(json.dumps({"history": []}))
elif command == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": "fixture", "status": "Invalid" if failure == "invalid" else "Accepted"}))
    if failure == "submit":
        sys.exit(1)
elif command == "xcrun" and args[0] == "stapler":
    if failure == args[1]:
        sys.exit(1)
elif command == "spctl" and failure == "gatekeeper":
    sys.exit(1)
'''


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gksdud-notary-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        shutil.copy2(ROOT / "build.sh", self.source)
        shutil.copy2(ROOT / "Info.plist", self.source)
        shutil.copy2(ROOT / "LICENSE", self.source)
        shutil.copytree(ROOT / "Resources", self.source / "Resources")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        shim = self.bin / "shim"
        shim.write_text(SHIM)
        shim.chmod(0o755)
        for name in ["mktemp", "swiftc", "iconutil", "lipo", "codesign", "ditto", "xcrun", "spctl"]:
            (self.bin / name).symlink_to(shim)
        self.output = self.root / "output"

    def build(self, failure="", notarize="1", mode="developer-id", existing=False):
        self.output.mkdir(exist_ok=True)
        if existing:
            (self.output / "gksdud-1.3.2-macos-universal.zip").write_bytes(b"previous build")
        env = {key: value for key, value in os.environ.items() if not key.startswith("GKSDUD_")}
        env.update(PATH=f"{self.bin}:{env['PATH']}", TEST_ROOT=str(self.root), TEST_FAILURE=failure,
                   GKSDUD_SIGN_MODE=mode, GKSDUD_SIGN_IDENTITY="A" * 40,
                   GKSDUD_NOTARIZE=notarize, GKSDUD_NOTARY_PROFILE="fixture-profile",
                   GKSDUD_NOTARY_KEYCHAIN="/private/tmp/fixture.keychain-db",
                   GKSDUD_OUTPUT_DIR=str(self.output))
        result = subprocess.run(["/bin/bash", str(self.source / "build.sh")], env=env,
                                capture_output=True, text=True, timeout=20)
        log = self.root / "calls.jsonl"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_accepted_app_is_stapled_and_verified_before_final_archive(self):
        result, calls = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        submit = next(i for i, c in enumerate(calls) if c[:3] == ["xcrun", "notarytool", "submit"])
        staple = next(i for i, c in enumerate(calls) if c[:3] == ["xcrun", "stapler", "staple"])
        validate = next(i for i, c in enumerate(calls) if c[:3] == ["xcrun", "stapler", "validate"])
        assess = next(i for i, c in enumerate(calls) if c[0] == "spctl")
        archive = next(i for i, c in enumerate(calls) if c[0] == "ditto" and c[-1].endswith("distribution.zip"))
        self.assertLess(submit, staple)
        self.assertLess(staple, validate)
        self.assertLess(validate, assess)
        self.assertLess(assess, archive)
        self.assertIn("--wait", calls[submit])
        self.assertIn("fixture-profile", calls[submit])
        self.assertIn("/private/tmp/fixture.keychain-db", calls[submit])
        self.assertEqual(len(list(self.output.glob("*.zip"))), 1)

    def test_each_failure_preserves_previous_archive(self):
        for failure in ["credentials", "submit", "invalid", "staple", "validate", "gatekeeper"]:
            with self.subTest(failure=failure):
                # Each failure needs its own stage because the mocked mktemp is deterministic.
                shutil.rmtree(self.root / "stage", ignore_errors=True)
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                result, calls = self.build(failure=failure, existing=True)
                self.assertNotEqual(result.returncode, 0, failure)
                self.assertEqual((self.output / "gksdud-1.3.2-macos-universal.zip").read_bytes(), b"previous build")
                self.assertFalse(any(c[0] == "ditto" and c[-1].endswith("distribution.zip") for c in calls))
                if failure == "credentials":
                    self.assertFalse(any(c[0] == "swiftc" for c in calls))

    def test_ad_hoc_notarization_is_rejected_before_build(self):
        result, calls = self.build(mode="ad-hoc")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Developer ID", result.stderr)
        self.assertEqual(calls, [])

    def test_development_build_does_not_contact_apple(self):
        result, calls = self.build(notarize="0", mode="ad-hoc")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(c[0] in ["xcrun", "spctl"] for c in calls))


if __name__ == "__main__":
    unittest.main()
