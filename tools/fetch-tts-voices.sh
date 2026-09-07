#!/bin/bash
set -euo pipefail

# Fetches the bundled Piper TTS voices (sherpa-layout: model.onnx +
# tokens.txt + espeak-ng-data/) into the app resources.
#
# The extracted dirs are gitignored (same convention as the .bin models)
# — re-run this after a fresh clone or before a device build.
# See docs/tts-implementation-plan.md.
#
# Verification policy (two tiers, deliberate):
# - google-medium + lessac-medium are the LEGACY bundled voices. Their
#   ModelCatalog sha256 is "" (the TTS "" convention) and they are not
#   verified here — backfill their hashes from the tts-models release
#   when their download delivery is pinned (the slice-A commentary on
#   ModelCatalog.sherpaKWSGigaSpeech explains the policy split).
# - chitwan-medium (voice-personalisation P0, slice B) has a REAL
#   sha256 — computed 2026-09-08 from the tts-models release asset, size
#   cross-checked against the GitHub release API — and is REQUIRED-
#   VERIFY at fetch time: the download is refused on any mismatch,
#   matching tools/fetch-kws-model.sh (slice A). If the model is ever
#   updated upstream, recompute and update BOTH this script and
#   ModelCatalog.piperNepaliChitwan.
#
# VOICES entries: name|expected_sha256|expected_size
# (empty sha/size = legacy tier, no verification)
VOICES=(
  "vits-piper-ne_NP-google-medium-int8||"
  "vits-piper-en_US-lessac-medium-int8||"
  "vits-piper-ne_NP-chitwan-medium-int8|deb1592efb99c02d38ba34443215ae94bf67ed77ecafd2e3320acffb27ae3204|21165758"
)
BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
DEST="$(cd "$(dirname "$0")/.." && pwd)/ios/ElderlyAssistant/Resources/Models/tts"

mkdir -p "$DEST"

for spec in "${VOICES[@]}"; do
  v="${spec%%|*}"
  rest="${spec#*|}"
  expected_sha="${rest%%|*}"
  expected_size="${rest#*|}"
  name="${v#vits-piper-}"
  if [ -d "$DEST/$name" ]; then
    echo "  ✓ $name already present — skipping"
    continue
  fi
  echo "  ↓ $name"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fL "$BASE_URL/$v.tar.bz2" -o "$tmp/$v.tar.bz2"

  if [ -n "$expected_sha" ]; then
    # REQUIRED-VERIFY at fetch time (see header): refuse on any mismatch.
    actual_sha="$(shasum -a 256 "$tmp/$v.tar.bz2" | awk '{print $1}')"
    actual_size="$(stat -f%z "$tmp/$v.tar.bz2")"
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "  ✗ sha256 mismatch for $v.tar.bz2" >&2
      echo "    expected: $expected_sha" >&2
      echo "    actual:   $actual_sha" >&2
      echo "    (download aborted — nothing was installed)" >&2
      exit 1
    fi
    if [ "$actual_size" != "$expected_size" ]; then
      echo "  ✗ size mismatch for $v.tar.bz2 (expected $expected_size, got $actual_size)" >&2
      exit 1
    fi
  fi

  tar -xjf "$tmp/$v.tar.bz2" -C "$tmp"
  mv "$tmp/$v" "$DEST/$name"
  rm -rf "$tmp"
  trap - EXIT
  echo "  ✓ $name installed ($(du -sh "$DEST/$name" | cut -f1))"
  if [ -n "$expected_sha" ]; then
    echo "  ✓ sha256 verified ($expected_sha)"
  fi
done

echo ""
echo "Done. Voices at: $DEST"
echo "Build the app — project.yml bundles Resources/Models/tts/ into the app."
