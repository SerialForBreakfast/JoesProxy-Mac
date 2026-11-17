#!/usr/bin/env python3
"""Retain selected XCTest PNG originals with a portable provenance manifest.

Selection JSON supplies test, attachmentPrefix, filename, caption and fixture.
Export attachments with xcresulttool first. Never infer identity from file order.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exports", type=pathlib.Path, required=True)
    parser.add_argument("--selection", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--app-info", type=pathlib.Path)
    parser.add_argument("--historical", action="store_true", help="Keep unavailable historical build/source identity unknown")
    args = parser.parse_args()
    entries = json.loads((args.exports / "manifest.json").read_text())
    selections = json.loads(args.selection.read_text())
    if args.historical:
        info, revision, dirty = {}, None, None
    else:
        if not args.app_info:
            parser.error("--app-info required for current captures")
        with args.app_info.open("rb") as source:
            info = plistlib.load(source)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        dirty = subprocess.check_output(["git", "status", "--short"], text=True).splitlines()
    records = []
    pending = []
    for selection in selections:
        matches = [attachment for entry in entries
                   if entry["testIdentifier"] == selection["test"]
                   for attachment in entry["attachments"]
                   if attachment["suggestedHumanReadableName"].startswith(selection["attachmentPrefix"])
                   and attachment["exportedFileName"].endswith(".png")]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one attachment for {selection['filename']}: {len(matches)}")
        attachment = matches[0]
        if attachment.get("isAssociatedWithFailure"):
            raise ValueError("Failure attachment requires separate archival review")
        filename = selection["filename"]
        exported = attachment["exportedFileName"]
        if pathlib.Path(filename).name != filename or pathlib.Path(exported).name != exported:
            raise ValueError("Only plain filenames are accepted")
        source = args.exports / exported
        data = source.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
            raise ValueError("Expected original PNG")
        width, height = struct.unpack(">II", data[16:24])
        destination = args.output / filename
        if destination.exists() and destination.read_bytes() != data:
            raise ValueError(f"Refusing to replace a different original: {filename}")
        pending.append((source, destination))
        records.append({**selection, "sha256": hashlib.sha256(data).hexdigest(),
                        "width": width, "height": height,
                        "timestamp": attachment["timestamp"],
                        "attachment": attachment["suggestedHumanReadableName"],
                        "exportedAttachment": exported, "resultBundle": args.result,
                        "crop": None, "privacyReview": selection.get("privacyReview", "pending visual review"),
                        "publicationApproval": "pending maintainer review",
                        "rights": "Project application UI and synthetic fixtures; maintainer confirmation pending"})
    args.output.mkdir(parents=True, exist_ok=True)
    for source, destination in pending:
        shutil.copyfile(source, destination)
    manifest = {"sourceCommit": revision, "dirtyPathsAtCollection": dirty,
                "buildKind": "historical capture; build identity unverified" if args.historical else "development checkout, not signed release",
                "appVersion": info.get("CFBundleShortVersionString"),
                "appBuild": info.get("CFBundleVersion"), "images": records}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Retained {len(records)} original PNGs in {args.output}")


if __name__ == "__main__":
    main()
