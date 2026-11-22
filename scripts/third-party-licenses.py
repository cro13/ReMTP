#!/usr/bin/env python3
"""Writes the license notices for the third-party crates linked into a ReMTP binary.

Usage: scripts/third-party-licenses.py --package remtp-ffi --output THIRD_PARTY_LICENSES.txt
       [--package remtp-cli] [--target aarch64-apple-darwin] [--target x86_64-apple-darwin]

The crate set is `cargo tree -e normal` for each package and target: normal dependencies with the
features that `cargo build -p <package>` resolves, so dev-dependencies, build scripts' dependencies and
other platforms' crates are left out (proc-macros are kept: their code is not linked, but listing them is
harmless). Workspace crates are ReMTP's own (see LICENSE) and are not listed.

For each crate the output has its name, version, license expression and the full text of every
LICENSE*/LICENCE*/COPYING*/NOTICE*/UNLICENSE* file in its published source (plus `license-file`).
MPL-2.0 crates also get the URL of their source code. Identical texts are printed once.

Fails when a crate's license is missing or not in ACCEPTED, or when a crate has no license file, unless
it is in NO_LICENSE_FILE with a reason. Python 3.9+ standard library only; reads the cargo registry, so
build (or `cargo fetch --locked`) first.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SPDX identifiers the project accepts in a dependency's license expression.
ACCEPTED = {
    "MIT",
    "Apache-2.0",
    "LLVM-exception",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "Zlib",
    "Unlicense",
    "Unicode-3.0",
    "BSL-1.0",
    "MPL-2.0",
}

# Crates that ship no license file. Each maps to a reason and the text to include instead
# (relative to the repo root).
NO_LICENSE_FILE = {
    # The uniffi-rs repository keeps one LICENSE at its root and doesn't copy it into each crate.
    # scripts/licenses/MPL-2.0.txt is that file at tag v0.32.2.
    name: (
        "uniffi-rs publishes its crates without the repository's LICENSE file",
        "scripts/licenses/MPL-2.0.txt",
    )
    for name in (
        "uniffi",
        "uniffi_bindgen",
        "uniffi_build",
        "uniffi_core",
        "uniffi_internal_macros",
        "uniffi_macros",
        "uniffi_meta",
        "uniffi_pipeline",
        "uniffi_udl",
    )
}

# Licenses whose terms require telling recipients where the source code is.
SOURCE_OFFER = {"MPL-2.0"}

LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notice|unlicense|copyright)([-_.].*)?$", re.IGNORECASE)
DEFAULT_TARGETS = ["aarch64-apple-darwin", "x86_64-apple-darwin"]


def cargo(*args):
    out = subprocess.run(
        ["cargo", *args, "--manifest-path", os.path.join(ROOT, "Cargo.toml"), "--locked"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return out.stdout


def shipped_crates(packages, targets):
    """(name, version) of every crate in the normal dependency graph of the packages."""
    crates = set()
    for package in packages:
        for target in targets:
            tree = cargo("tree", "-q", "-e", "normal", "-p", package, "--target", target, "--prefix", "none", "--format", "{p}")
            for line in tree.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[1].startswith("v"):
                    crates.add((parts[0], parts[1][1:]))
    return crates


def license_ids(expression):
    """SPDX identifiers in a license expression ("MIT/Apache-2.0" is the old spelling of OR)."""
    tokens = re.split(r"[\s()/]+", expression)
    return {t for t in tokens if t and t not in ("AND", "OR", "WITH")}


def license_files(package):
    folder = os.path.dirname(package["manifest_path"])
    names = sorted(n for n in os.listdir(folder) if LICENSE_FILE.match(n) and os.path.isfile(os.path.join(folder, n)))
    paths = [os.path.join(folder, n) for n in names]
    if package.get("license_file"):
        extra = os.path.normpath(os.path.join(folder, package["license_file"]))
        if extra not in paths and os.path.isfile(extra):
            paths.append(extra)
    return paths


def read_text(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8", errors="replace").replace("\r\n", "\n").strip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--package", action="append", required=True, help="workspace package that is shipped")
    parser.add_argument("--target", action="append", help="target triple (default: both macOS targets)")
    parser.add_argument("--output", required=True)
    parser.add_argument("--title", default="ReMTP")
    args = parser.parse_args()
    targets = args.target or DEFAULT_TARGETS

    metadata = json.loads(cargo("metadata", "--format-version", "1"))
    by_id = {(p["name"], p["version"]): p for p in metadata["packages"]}
    wanted = shipped_crates(args.package, targets)

    errors = []
    entries = []
    for key in sorted(wanted, key=lambda k: (k[0].lower(), k[1])):
        package = by_id.get(key)
        if package is None:
            errors.append(f"{key[0]} {key[1]}: not in cargo metadata")
            continue
        if package["source"] is None:
            continue  # workspace crate
        name, version = key
        expression = package.get("license") or ""
        if not expression:
            errors.append(f"{name} {version}: no license expression in Cargo.toml")
        else:
            unknown = license_ids(expression) - ACCEPTED
            if unknown:
                errors.append(f"{name} {version}: license {expression!r} has unaccepted terms {sorted(unknown)}")
        files = [(os.path.basename(p), read_text(p)) for p in license_files(package)]
        note = None
        if not files:
            if name in NO_LICENSE_FILE:
                note, substitute = NO_LICENSE_FILE[name]
                files = [(os.path.basename(substitute), read_text(os.path.join(ROOT, substitute)))]
            else:
                errors.append(f"{name} {version} ({expression}): no license file in {os.path.dirname(package['manifest_path'])}")
        entries.append((package, expression, files, note))

    if errors:
        print("third-party-licenses: " + "\n  ".join(["failed:"] + errors), file=sys.stderr)
        return 1

    out = []
    out.append(f"{args.title}: third-party licenses")
    out.append("=" * len(out[0]))
    out.append("")
    out.append(f"This program includes the following {len(entries)} Rust crates (from crates.io), under their own")
    out.append("licenses. Where a crate offers a choice of licenses, ReMTP uses it under any one of them.")
    out.append("ReMTP itself is under the MIT License (LICENSE.txt). Source code of ReMTP: https://github.com/cro13/ReMTP")
    out.append("")
    offers = [e for e in entries if license_ids(e[1]) & SOURCE_OFFER]
    if offers:
        out.append("Source code of the MPL-2.0 crates included here is available at:")
        for package, _, _, _ in offers:
            out.append(f"  {package['name']} {package['version']}: {source_url(package)}")
        out.append("")
    out.append("Summary")
    out.append("-------")
    for package, expression, _, _ in entries:
        out.append(f"  {package['name']} {package['version']}  ({expression})")
    out.append("")

    seen = {}
    for package, expression, files, note in entries:
        heading = f"{package['name']} {package['version']}"
        out.append("")
        out.append("-" * 78)
        out.append(heading)
        out.append(f"License: {expression}")
        if package.get("repository"):
            out.append(f"Repository: {package['repository']}")
        if license_ids(expression) & SOURCE_OFFER:
            out.append(f"Source code: {source_url(package)}")
            out.append(f"  (also https://crates.io/crates/{package['name']}/{package['version']})")
        if note:
            out.append(f"Note: {note}; the text below is the project's LICENSE.")
        out.append("-" * 78)
        for file_name, text in files:
            digest = hashlib.sha256(text.encode()).hexdigest()
            out.append("")
            if digest in seen:
                out.append(f"{file_name}: identical to {seen[digest]} above.")
            else:
                seen[digest] = f"{file_name} of {heading}"
                out.append(f"{file_name}:")
                out.append("")
                out.append(text.rstrip("\n"))

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    counts = {}
    for _, expression, _, _ in entries:
        counts[expression] = counts.get(expression, 0) + 1
    print(f"third-party-licenses: {len(entries)} crates ({', '.join(args.package)}; {', '.join(targets)}) -> {args.output}", file=sys.stderr)
    for expression, count in sorted(counts.items(), key=lambda c: -c[1]):
        print(f"  {count:4}  {expression}", file=sys.stderr)
    substituted = [e[0]["name"] for e in entries if e[3]]
    if substituted:
        print(f"  license text from scripts/licenses/ (allow-listed): {', '.join(substituted)}", file=sys.stderr)
    return 0


def source_url(package):
    """The crate's repository at its version tag (the published crate itself is on crates.io)."""
    repo = (package.get("repository") or "").rstrip("/")
    if repo.endswith(".git"):
        repo = repo[:-4]
    if not repo:
        return f"https://crates.io/crates/{package['name']}/{package['version']}"
    if "github.com" in repo:
        return f"{repo}/tree/v{package['version']}"
    return f"{repo} (version {package['version']})"


if __name__ == "__main__":
    sys.exit(main())
