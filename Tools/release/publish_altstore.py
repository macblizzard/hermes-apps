#!/usr/bin/env python3
"""Publish an unsigned iOS build to a public GitHub-hosted sideload source.

Why GitHub instead of the tailnet file server: a sideloading front end fetches its source over the
public internet and caches it aggressively. A tailnet-only URL can only be reached with Tailscale up,
and the front end kept serving a list it had already fetched. GitHub gives a public HTTPS URL with
real CDN semantics, and release assets give the IPA a stable, permanent address.

Layout mirrors macblizzard/musike-altstore:

  <repo>/altstore.json                                    <- add this URL in the installer
  <repo>/releases/download/v<build>/Hermes-<version>.ipa   <- the build itself

`date` is the IPA's mtime (UTC), `version`/`buildVersion` come from the IPA's Info.plist, and the new
entry is prepended so the newest build is always first. Old entries are trimmed, but their release
assets are left alone: an installed device may still be pointing at one.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publish_source import read_ipa  # noqa: E402  (same directory, shared IPA reader)

SOURCE_NAME = "Hermes"
SOURCE_ID = "net.corvus.hermes.source"
ICON_URL = "https://raw.githubusercontent.com/macblizzard/hermes-altstore/main/icon-512.png"


def run(cmd: list[str], **kwargs) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(cmd[:3])} failed:\n{result.stderr.strip()}")
    return result.stdout


def release_exists(repo: str, tag: str) -> bool:
    return subprocess.run(["gh", "release", "view", tag, "-R", repo],
                          capture_output=True, text=True).returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--mac-zip", type=Path)
    parser.add_argument("--repo", default="macblizzard/hermes-altstore")
    parser.add_argument("--notes", default="")
    parser.add_argument("--keep", type=int, default=5)
    args = parser.parse_args()

    info = read_ipa(args.ipa)
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    bundle = str(info["CFBundleIdentifier"])
    min_os = str(info.get("MinimumOSVersion") or "17.0")
    data = args.ipa.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    stamp = dt.datetime.fromtimestamp(args.ipa.stat().st_mtime, dt.timezone.utc)

    tag = f"v{build}"
    asset_name = f"Hermes-{version}-b{build}.ipa"
    download = f"https://github.com/{args.repo}/releases/download/{tag}/{asset_name}"

    if not release_exists(args.repo, tag):
        staging = Path(tempfile.mkdtemp())
        try:
            shutil.copy2(args.ipa, staging / asset_name)
            files = [str(staging / asset_name)]
            if args.mac_zip and args.mac_zip.exists():
                shutil.copy2(args.mac_zip, staging / args.mac_zip.name)
                files.append(str(staging / args.mac_zip.name))
            run(["gh", "release", "create", tag, *files,
                 "-R", args.repo,
                 "--title", f"{SOURCE_NAME} {version} ({build})",
                 "--notes", args.notes or f"Build {version} ({build})."])
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        print(f"  release {tag}: {asset_name}")
    else:
        print(f"  release {tag} already exists — reusing it")

    entry = {
        "version": version,
        "buildVersion": build,
        "date": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": args.notes or f"Build {version} ({build}).",
        "downloadURL": download,
        "size": len(data),
        "minOSVersion": min_os,
        "sha256": digest,
    }

    work = Path(tempfile.mkdtemp())
    try:
        run(["git", "clone", "--depth", "1", f"https://github.com/{args.repo}.git", str(work)])
        path = work / "altstore.json"
        source = json.loads(path.read_text()) if path.exists() else {}
        app = (source.get("apps") or [{}])[0]
        versions = [v for v in app.get("versions", [])
                    if not (v.get("version") == version and v.get("buildVersion") == build)]
        versions.insert(0, entry)
        app.update({
            "name": SOURCE_NAME,
            "bundleIdentifier": bundle,
            "developerName": "macblizzard",
            "subtitle": "Hermes Agent client",
            "localizedDescription": "Native client for a self-hosted Hermes Agent gateway.",
            "iconURL": ICON_URL,
            "tintColor": "#007CF7",
            "category": "utilities",
            "screenshots": [],
            "versions": versions[:args.keep],
            "appPermissions": {"entitlements": [], "privacy": {
                "NSCameraUsageDescription": "Scan the pairing code shown by your Hermes host to connect this device."}},
        })
        source.update({
            "name": "Hermes",
            "identifier": SOURCE_ID,
            "sourceURL": f"https://raw.githubusercontent.com/{args.repo}/main/altstore.json",
            "schemaVersion": source.get("schemaVersion", 1),
            "subtitle": "Hermes Agent",
            "description": "Unsigned builds of the Hermes native client, published automatically from CI.",
            "iconURL": ICON_URL,
            "headerURL": ICON_URL,
            "tintColor": "#007CF7",
            "featuredApps": [bundle],
            "apps": [app],
            "news": source.get("news", []),
        })
        path.write_text(json.dumps(source, indent=2) + "\n")

        icon = Path(__file__).resolve().parent / "app-icon-512.png"
        if icon.exists() and not (work / "icon-512.png").exists():
            shutil.copy2(icon, work / "icon-512.png")

        run(["git", "-C", str(work), "add", "altstore.json", "icon-512.png"])
        run(["git", "-C", str(work), "-c", "user.name=cody",
             "-c", "user.email=cody@corvus.local",
             "commit", "-m", f"publish {version} ({build})"])
        run(["git", "-C", str(work), "push", "origin", "HEAD:main"])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(f"\n  source   https://raw.githubusercontent.com/{args.repo}/main/altstore.json")
    print(f"  ipa      {download}  ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
