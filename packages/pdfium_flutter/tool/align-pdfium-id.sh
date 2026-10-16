#!/usr/bin/env bash
# align-pdfium-id.sh — make every slice of PDFium.xcframework loadable on
# macOS 27. SwiftPM's binary target is named PDFium, so the app requests
# @rpath/PDFium.framework/PDFium. Upstream's xcframework still carries
# Chromium's dylib id @rpath/pdfium.framework/pdfium; dyld treats that
# case mismatch as fatal. Called from fetch-native.sh AFTER the zip has
# been SHA-256 + SLSA verified — the archive stays byte-identical to
# espresso3389; only the extracted tree is rewritten.
#
#   Usage:  bash tool/align-pdfium-id.sh path/to/PDFium.xcframework
set -euo pipefail

XCF="${1:-}"
[ -n "$XCF" ] && [ -d "$XCF" ] || { echo "usage: $0 PDFium.xcframework" >&2; exit 2; }
command -v install_name_tool >/dev/null || { echo "install_name_tool not found (Darwin only)" >&2; exit 1; }
command -v otool >/dev/null || { echo "otool not found" >&2; exit 1; }

WANT_NAME="PDFium"
WANT_ID="@rpath/${WANT_NAME}.framework/${WANT_NAME}"

is_macho() {
  [ -f "$1" ] && file -b "$1" | grep -q 'Mach-O'
}

framework_binary() {
  local fw="$1" n
  n="$(basename "$fw" .framework)"
  local cand
  for cand in \
    "$fw/Versions/Current/$WANT_NAME" \
    "$fw/Versions/Current/$n" \
    "$fw/Versions/Current/pdfium" \
    "$fw/Versions/A/$WANT_NAME" \
    "$fw/Versions/A/$n" \
    "$fw/Versions/A/pdfium" \
    "$fw/$WANT_NAME" \
    "$fw/$n" \
    "$fw/pdfium"
  do
    if is_macho "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

align_one() {
  local fw="$1"
  local bin id leaf dest plist
  bin="$(framework_binary "$fw")" || {
    echo "❌ no Mach-O in $fw" >&2
    return 1
  }

  codesign --remove-signature "$bin" >/dev/null 2>&1 || true
  id="$(otool -D "$bin" | tail -1)"
  if [ "$id" != "$WANT_ID" ]; then
    echo "▸ $fw: $id -> $WANT_ID"
    install_name_tool -id "$WANT_ID" "$bin"
  fi

  # APFS often preserves the original dirent case; `mv pdfium PDFium` is a
  # no-op and even `basename` of a path we spelled PDFium can still be pdfium.
  bin="$(python3 - "$bin" "$WANT_NAME" <<'PY'
import os, sys
src, want = sys.argv[1], sys.argv[2]
d = os.path.dirname(src)
actual = next(
    (n for n in os.listdir(d)
     if n.lower() == os.path.basename(src).lower()
     and os.path.isfile(os.path.join(d, n))),
    os.path.basename(src),
)
dst = os.path.join(d, want)
if actual != want:
    tmp = os.path.join(d, f".align-id-{os.getpid()}")
    os.rename(os.path.join(d, actual), tmp)
    os.rename(tmp, dst)
print(dst)
PY
)"
  if [ -d "$fw/Versions" ]; then
    python3 - "$fw" "$WANT_NAME" <<'PY'
import os, sys
fw, want = sys.argv[1], sys.argv[2]
tmp = os.path.join(fw, f".align-link-{os.getpid()}")
if os.path.lexists(tmp):
    os.remove(tmp)
os.symlink(f"Versions/Current/{want}", tmp)
dest = os.path.join(fw, want)
# Replace a same-name-ignoring-case symlink/file at the framework root.
for n in list(os.listdir(fw)):
    if n.lower() == want.lower() and n != want:
        os.remove(os.path.join(fw, n))
        break
os.replace(tmp, dest)
PY
  fi

  plist="$(find "$fw" -name Info.plist | head -1)"
  if [ -n "$plist" ] && command -v plutil >/dev/null; then
    plutil -replace CFBundleExecutable -string "$WANT_NAME" "$plist" 2>/dev/null || true
  fi

  codesign --force --sign - "$bin" >/dev/null 2>&1 || true

  id="$(otool -D "$bin" | tail -1)"
  [ "${id##*/}" = "$WANT_NAME" ] || {
    echo "❌ $fw install name '$id' does not end in '$WANT_NAME'" >&2
    return 1
  }
  echo "✅ $fw -> $id"
}

found=0
while IFS= read -r fw; do
  found=1
  align_one "$fw"
done < <(find "$XCF" -name '*.framework' -type d)

[ "$found" -eq 1 ] || { echo "❌ no .framework slices in $XCF" >&2; exit 1; }
