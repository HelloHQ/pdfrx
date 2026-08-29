#!/usr/bin/env bash
# fetch-native.sh — pdfium_flutter's TRUST GATE for the PDFium xcframework.
#
# Downloads the pinned mirror release (native/artifacts.lock), then — BEFORE
# extracting anything — verifies:
#   1. SHA-256 against the committed manifest value (== upstream's SwiftPM
#      checksum, so this is provably the same artifact upstream ships), and
#   2. SLSA build provenance via `gh attestation verify`.
# Only then does it extract into darwin/pdfium_flutter/Frameworks/. Same
# contract as hellohq_db's gate; a compromised mirror aborts here.
#
#   Usage:  bash tool/fetch-native.sh
# Requires: gh (authenticated), shasum, unzip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${ROOT}/native/artifacts.lock"
DEST="${ROOT}/darwin/pdfium_flutter/Frameworks"

val() { grep -E "^$1:" "${LOCK}" | head -1 | cut -d: -f2- | tr -d ' '; }
REPO="$(val REPO)"; TAG="$(val RELEASE_TAG)"; ARCHIVE="$(val ARCHIVE)"; SHA="$(val SHA256)"
[ -n "${REPO}" ] && [ -n "${TAG}" ] && [ -n "${ARCHIVE}" ] && [ -n "${SHA}" ] \
  || { echo "❌ artifacts.lock missing REPO/RELEASE_TAG/ARCHIVE/SHA256" >&2; exit 1; }

if [ -d "${DEST}/PDFium.xcframework" ] && [ -f "${DEST}/.provisioned-${TAG}" ]; then
  echo "✅ PDFium.xcframework already provisioned (${TAG})"; exit 0
fi

STAGE="$(mktemp -d)"; trap 'rm -rf "${STAGE}"' EXIT
echo "▸ ${REPO} @ ${TAG} · ${ARCHIVE}"
gh release download "${TAG}" --repo "${REPO}" --pattern "${ARCHIVE}" -O "${STAGE}/${ARCHIVE}"

echo "${SHA}  ${STAGE}/${ARCHIVE}" | shasum -a 256 -c -
gh attestation verify "${STAGE}/${ARCHIVE}" --repo "${REPO}" >/dev/null
echo "✅ verified (sha256 + attestation)"

mkdir -p "${DEST}"
rm -rf "${DEST}/PDFium.xcframework"
unzip -q "${STAGE}/${ARCHIVE}" -d "${STAGE}/x"
FW="$(find "${STAGE}/x" -maxdepth 3 -name 'PDFium.xcframework' -type d | head -1)"
[ -n "${FW}" ] || { echo "❌ archive did not contain PDFium.xcframework" >&2; find "${STAGE}/x" -maxdepth 2 >&2; exit 1; }
mv "${FW}" "${DEST}/PDFium.xcframework"
rm -f "${DEST}"/.provisioned-* ; touch "${DEST}/.provisioned-${TAG}"
echo "✅ PDFium.xcframework provisioned into ${DEST}"
