#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the freestanding AArch64 Win32 guest helpers:
#   build/opt_hive_arm64.exe   (tools/opt_hive_arm64.c, console, entry mainCRTStartup)
#   build/WinIOSBrowser.exe    (tools/winios_browser_arm64.c, GUI, entry WinMainCRTStartup)
#
# The upstream repo ships the sources but no build rule (README only says
# "llvm/lld"). Both sources are fully freestanding: they declare their own
# Win32 imports and never call libc (no memcpy/memset/strlen), so all they
# need is clang + lld plus import libraries, which llvm-dlltool generates
# from the .def files in tools/win32/.
#
# Requires Homebrew LLVM (clang, lld, llvm-dlltool):
#   brew install llvm
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT/win32"

LLVM_BIN="${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}"
CLANG="${CLANG:-$LLVM_BIN/clang}"
DLLTOOL="${DLLTOOL:-$LLVM_BIN/llvm-dlltool}"
[ -x "$CLANG" ] || CLANG="$(command -v clang)"
[ -x "$DLLTOOL" ] || DLLTOOL="$(command -v llvm-dlltool)"
echo "clang:   $CLANG"
echo "dlltool: $DLLTOOL"

# 1. Import libraries from the .def files (function lists mirror the
#    __declspec(dllimport) declarations in the sources).
for dll in kernel32 advapi32 ws2_32; do
    "$DLLTOOL" -m arm64 -d "$ROOT/tools/win32/$dll.def" -l "$OUT/win32/$dll.lib"
done

CFLAGS=(--target=aarch64-pc-windows-msvc -O2 -ffreestanding -nostdlib
        -fno-stack-protector -fuse-ld=lld -Wno-unused-parameter)

# 2. opt_hive_arm64.exe: console subsystem, kernel32 + advapi32.
"$CLANG" "${CFLAGS[@]}" \
    -Wl,-entry:mainCRTStartup -Wl,-subsystem:console \
    "$ROOT/tools/opt_hive_arm64.c" \
    "$OUT/win32/kernel32.lib" "$OUT/win32/advapi32.lib" \
    -o "$OUT/opt_hive_arm64.exe"

# 3. WinIOSBrowser.exe: windows subsystem, kernel32 + ws2_32.
"$CLANG" "${CFLAGS[@]}" \
    -Wl,-entry:WinMainCRTStartup -Wl,-subsystem:windows \
    "$ROOT/tools/winios_browser_arm64.c" \
    "$OUT/win32/kernel32.lib" "$OUT/win32/ws2_32.lib" \
    -o "$OUT/WinIOSBrowser.exe"

ls -lh "$OUT/opt_hive_arm64.exe" "$OUT/WinIOSBrowser.exe"
echo "=== guest helpers built ==="
