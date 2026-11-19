#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetch Windows 11 ARM64 installation media for the provisioning scripts
# and place a retail-layout ESD at work/downloads/Win11_24H2_ARM64_en-us.esd
# (the exact path/name scripts/provision_windows_arm64.py and
# scripts/optimize_windows_lite.py hard-code).
#
# Two sources, in priority order:
#   1. ESD_URL set: download that ESD directly (escape hatch for a fresh
#      Microsoft software-download link, which is session/time limited).
#   2. UUP dump (default): resolve a Windows 11 ARM64 consumer build via
#      the public UUP dump JSON API (https://api.uupdump.net), download
#      the Professional UUP file set -- every file is served from
#      Microsoft's own update servers and verified against the SHA-1 the
#      API publishes -- convert it to an ISO with the official UUP dump
#      converter, and rebuild a retail-layout ESD from the ISO with
#      scripts/ci/build_synthetic_esd.sh.
#
# Environment:
#   ESD_URL     direct .esd URL (optional)
#   UUP_UUID    UUP update UUID (optional; default: newest match below)
#   UUP_SEARCH  listid search string (default: 26100)
#   UUP_LANG    language code for the UUP set (default: en-us)
#   UUP_EDITION edition for the UUP set (default: professional)
#
# Requires: curl, python3, aria2 (optional, curl fallback), git, wimlib,
# plus the converter's own macOS deps (cabextract, chntpw).
set -euo pipefail
trap 'echo "::error::fetch_uup_esd.sh failed at line $LINENO: ${BASH_COMMAND:0:300}" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/work"
OUT_ESD="$WORK/downloads/Win11_24H2_ARM64_en-us.esd"
API="https://api.uupdump.net"
UUP_DIR="$WORK/uup"
mkdir -p "$WORK/downloads"

if [ -n "${ESD_URL:-}" ]; then
    echo "== Downloading ESD directly from ESD_URL =="
    curl -L --fail --retry 3 -o "$OUT_ESD" "$ESD_URL"
    ls -lh "$OUT_ESD"
    echo "=== ESD ready (direct URL) ==="
    exit 0
fi

UUID="${UUP_UUID:-}"
SEARCH="${UUP_SEARCH:-26100}"
LANG_CODE="${UUP_LANG:-en-us}"
EDITION="${UUP_EDITION:-professional}"

if [ -z "$UUID" ]; then
    echo "== Resolving newest Windows 11 ARM64 build (search='$SEARCH') via UUP dump API =="
    curl -s --fail "$API/listid.php?search=$SEARCH&sortByDate=1" -o "$WORK/listid.json"
    UUID="$(python3 - "$WORK/listid.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
builds = d["response"]["builds"]
cands = []
for uuid, b in builds.items():
    title = b.get("title", "")
    if b.get("arch") == "arm64" and title.startswith("Windows 11"):
        cands.append((b.get("created") or 0, uuid, title))
cands.sort(reverse=True)
if not cands:
    sys.exit("no Windows 11 arm64 build matched the search")
print(cands[0][1], file=sys.stderr)
sys.stdout.write(cands[0][1])
PYEOF
)"
    echo "Resolved UUP build UUID: $UUID"
fi

echo "== Checking language availability ($LANG_CODE) =="
curl -s --fail "$API/listlangs.php?id=$UUID" -o "$WORK/listlangs.json" || true
if [ -s "$WORK/listlangs.json" ] && ! grep -qi "\"$LANG_CODE\"" "$WORK/listlangs.json"; then
    echo "::warning::language '$LANG_CODE' not found in listlangs response for $UUID; continuing (get.php will fail loudly if unusable)"
fi

echo "== Fetching UUP file list (lang=$LANG_CODE edition=$EDITION) =="
curl -s --fail "$API/get.php?id=$UUID&lang=$LANG_CODE&edition=$EDITION" -o "$WORK/uup_files.json"

echo "== Downloading UUP set from Microsoft update servers =="
rm -rf "$UUP_DIR"
mkdir -p "$UUP_DIR"
python3 - "$WORK/uup_files.json" "$UUP_DIR" <<'PYEOF'
import json, sys
from pathlib import Path
d = json.load(open(sys.argv[1]))
files = d["response"]["files"]
outdir = Path(sys.argv[2])
with open(outdir / "aria2.txt", "w") as f:
    for name, meta in files.items():
        f.write(meta["url"] + "\n")
        f.write(f"  out={name}\n")
        if meta.get("sha1"):
            f.write(f"  checksum=sha-1={meta['sha1']}\n")
print(f"{len(files)} UUP files queued")
PYEOF
if command -v aria2c >/dev/null 2>&1; then
    aria2c -i "$UUP_DIR/aria2.txt" -d "$UUP_DIR" -j 5 -x 1 --file-allocation=none
else
    echo "::warning::aria2c not found; falling back to sequential curl (SHA-1 verified afterwards)"
    python3 - "$WORK/uup_files.json" "$UUP_DIR" <<'PYEOF'
import json, subprocess, sys
from pathlib import Path
d = json.load(open(sys.argv[1]))
outdir = Path(sys.argv[2])
for name, meta in d["response"]["files"].items():
    dest = outdir / name
    if not dest.exists():
        subprocess.run(["curl", "-L", "--fail", "--retry", "3", "-o", str(dest), meta["url"]], check=True)
    if meta.get("sha1"):
        got = subprocess.check_output(["shasum", "-a", "1", str(dest)]).split()[0].decode()
        if got.lower() != meta["sha1"].lower():
            sys.exit(f"SHA-1 mismatch for {name}")
print("curl fallback download + SHA-1 verification complete")
PYEOF
fi
du -sh "$UUP_DIR"

echo "== Converting UUP set to ISO (official UUP dump converter) =="
CONV_DIR="$WORK/converter"
rm -rf "$CONV_DIR"
git clone --depth 1 https://git.uupdump.net/uup-dump/converter.git "$CONV_DIR" \
    || git clone --depth 1 https://github.com/uup-dump/converter.git "$CONV_DIR"
# The converter's macOS entry point is convert.sh; depending on revision it
# either runs inside the UUP folder or takes the folder as an argument.
# Try the in-folder form first, then the argument form, and accept the
# first ISO that appears anywhere under work/.
( cd "$UUP_DIR" && bash "$CONV_DIR/convert.sh" ) || true
ISO_PATH="$(find "$WORK" -name '*.iso' -type f 2>/dev/null | head -1 || true)"
if [ -z "$ISO_PATH" ]; then
    ( cd "$WORK" && bash "$CONV_DIR/convert.sh" "$UUP_DIR" "Win11_ARM64_UUP.iso" ) || true
    ISO_PATH="$(find "$WORK" -name '*.iso' -type f 2>/dev/null | head -1 || true)"
fi
[ -n "$ISO_PATH" ] && [ -f "$ISO_PATH" ] || { echo "::error::converter produced no ISO under $WORK"; ls -la "$WORK" "$UUP_DIR"; exit 1; }
echo "Converter produced: $ISO_PATH"

echo "== Rebuilding retail-layout ESD from ISO =="
bash "$ROOT/scripts/ci/build_synthetic_esd.sh" "$ISO_PATH" "$OUT_ESD"

rm -rf "$UUP_DIR" "$CONV_DIR" "$ISO_PATH"
ls -lh "$OUT_ESD"
echo "=== ESD ready (UUP route) ==="
