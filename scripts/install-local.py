#!/usr/bin/env python3
"""Install a built app, handing its login preference from the old bundle to the new one."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.eddie.protectears"


def metadata(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "ProtectEars":
        raise RuntimeError(f"Not a Protect Ears bundle: {app}")
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "dist/release/Protect Ears.app")
    parser.add_argument("--destination", type=Path, default=ROOT / "dist/Protect Ears.app")
    parser.add_argument("--no-open", action="store_true", help="Leave launching the updated app to the caller")
    legacy = parser.add_mutually_exclusive_group()
    legacy.add_argument("--legacy-login-on", action="store_true", help="Migrate a known ON choice from v1.0.2 or earlier")
    legacy.add_argument("--legacy-login-off", action="store_true", help="Migrate a known OFF choice from v1.0.2 or earlier")
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.destination.absolute()
    if source == destination.resolve() or destination.is_symlink():
        parser.error("Source and destination must be separate real app bundles")
    new_info = metadata(source)
    old_info = metadata(destination) if destination.exists() else None
    supported = old_info is not None and int(old_info["CFBundleVersion"]) >= 4
    migrating = args.legacy_login_on or args.legacy_login_off
    if old_info and not supported and not migrating:
        parser.error("For v1.0.2 or earlier, specify --legacy-login-on or --legacy-login-off to preserve your known choice")
    if migrating and (old_info is None or supported):
        parser.error("Legacy flags apply only when replacing v1.0.2 or earlier")
    if old_info and int(new_info["CFBundleVersion"]) < int(old_info["CFBundleVersion"]):
        parser.error("Refusing to replace the app with an older build")

    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".protect-ears-update-", dir=destination.parent))
    staged_app = staging / "Protect Ears.app"
    backup = ROOT / ".build/installed-backups" / ("Protect Ears-" + uuid.uuid4().hex + ".app")
    executable = destination / "Contents/MacOS/ProtectEars"
    prepared = False
    replaced = False
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]

    def process_path(pid):
        buffer = ctypes.create_string_buffer(4096)
        return buffer.value.decode() if libproc.proc_pidpath(pid, buffer, len(buffer)) > 0 else None

    try:
        subprocess.run(["ditto", str(source), str(staged_app)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True)
        if supported:
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
            subprocess.run([str(executable), "--prepare-for-update"], check=True)
            prepared = True
        elif migrating:
            # Older versions cannot export intent. This explicit flag records
            # the user's known choice; it must never be guessed from a missing item.
            record = dict(requested=args.legacy_login_on, build="legacy", lastStatus=1 if args.legacy_login_on else 0,
                          preparedForUpdate=True, approvalRequired=False)
            payload = json.dumps(record, separators=(",", ":")).encode().hex()
            subprocess.run(["defaults", "write", BUNDLE_ID, "loginItemPreference", "-data", payload], check=True)

        processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
        pids = [int(line.split(None, 1)[0]) for line in processes.splitlines()
                if len(line.split(None, 1)) == 2 and line.split(None, 1)[1] == str(executable)]
        for pid in pids:
            if process_path(pid) == str(executable):
                os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while any(process_path(pid) == str(executable) for pid in pids):
            if time.monotonic() >= deadline:
                raise RuntimeError("Old app did not exit; its bundle was not replaced")
            time.sleep(0.05)
        if old_info:
            backup.parent.mkdir(parents=True, exist_ok=True)
            destination.rename(backup)
        staged_app.rename(destination)
        replaced = True
        if not args.no_open:
            subprocess.run(["open", str(destination)], check=True)
        print(f"Installed {new_info['CFBundleShortVersionString']} at {destination}. Open the updated app once to restore its login choice.")
    except Exception:
        if backup.exists():
            if replaced:
                destination.rename(staged_app)
            backup.rename(destination)
        if prepared and executable.exists():
            subprocess.run([str(executable), "--restore-login-registration"], check=False)
        raise
    finally:
        shutil.rmtree(staging)


if __name__ == "__main__":
    main()
