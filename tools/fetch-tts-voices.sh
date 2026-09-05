#!/bin/bash
set -euo pipefail

# Fetches the bundled Piper TTS voices (sherpa-layout: model.onnx +
# tokens.txt + espeak-ng-data/) into the app resources.
#
# The extracted dirs are gitignored (same convention as the .bin models)
# — re-run this after a fresh clone or before a device build.
# See docs/tts-implementation-plan.md.

VOICES=(
  vits-piper-ne_NP-google-medium-int8
  vits-piper-en_US-lessac-medium-int8
)
BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
DEST="$(cd "$(dirname "$0")/.." && pwd)/ios/ElderlyAssistant/Resources/Models/tts"

mkdir -p "$DEST"

for v in "${VOICES[@]}"; do
  name="${v#vits-piper-}"
  if [ -d "$DEST/$name" ]; then
    echo "  ✓ $name already present — skipping"
    continue
  fi
  echo "  ↓ $name"
  tmp="$(mktemp -d)"
  curl -sL "$BASE_URL/$v.tar.bz2" -o "$tmp/$v.tar.bz2"
  tar -xjf "$tmp/$v.tar.bz2" -C "$tmp"
  mv "$tmp/$v" "$DEST/$name"
  rm -rf "$tmp"
  echo "  ✓ $name installed ($(du -sh "$DEST/$name" | cut -f1))"
done

echo ""
echo "Done. Voices at: $DEST"
echo "Build the app — project.yml bundles Resources/Models/tts/ into the app."
