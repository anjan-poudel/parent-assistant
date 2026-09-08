#!/bin/bash
set -euo pipefail

# Fetches the bundled sherpa-onnx wake-word model (KWS, "Hey Sahayak")
# into the app resources.
#
# The extracted dir is gitignored (same convention as the TTS voices and
# .bin models) — re-run this after a fresh clone or before a device build.
# See docs/voice-personalisation-p0-plan.md (slice A) and
# docs/research-sections/speaker-fingerprint.md §5.
#
# Model: sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01
#   (Apache-2.0, streaming Zipformer transducer, English, int8 ≈ 5 MB)
#   https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/...
#
# sha256 is REAL (computed 2026-09-08 from the kws-models release asset)
# and is REQUIRED-VERIFY at fetch time: the download is refused on any
# mismatch, so a corrupted artifact can never reach the bundle. This is
# the deliberate opposite of the TTS entries' "" convention — the KWS
# engine feeds the always-on mic, so its bytes are pinned. If the model
# is ever updated upstream, recompute and update BOTH this script and
# ModelCatalog.sherpaKWSGigaSpeech.

MODEL="sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models"
EXPECTED_SHA256="f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a"
EXPECTED_SIZE="17626723"
DEST="$(cd "$(dirname "$0")/.." && pwd)/ios/ElderlyAssistant/Resources/Models/kws"

# Keyword configuration. The sherpa KWS runtime does NOT tokenize raw
# text (csrc/utils.cc EncodeKeywords): every space-separated token must
# exist in the model's tokens.txt, so the phrase is pre-tokenized here
# with the model's own sentencepiece model (Nepali "ये कान्छी" romanized
# "YEAH KANCHHI" → "▁YEAH ▁K AN CH H I", verified against tokens.txt on
# 2026-09-08; "YEAH" is the closest English word-start tokenization of
# "ये" — the GigaSpeech English BPE vocabulary has no word-start "Y").
# keywords.txt is the runtime file the engine reads — edit it to change
# the phrase without retraining. Line syntax: tokens plus optional
# ":score" and "#threshold" suffixes (defaults keywordsScore 1.0 /
# keywordsThreshold 0.25 apply when omitted); "@phrase" is only needed
# when a keyword differs from its tokens, which is never the case here.
# Acoustic candidate set for the one phrase (Nepali "ये कान्छी"). The
# English-trained GigaSpeech decoder maps the user's Nepali phones to
# its nearest English subword tokens, which vary (aspiration, vowel
# quality, trailing iy) — so keywords.txt ships every plausible
# tokenization instead of betting on one. The aspirated CH-H form is
# included for completeness though it is essentially never emitted.
# keywords.txt supports multiple keywords; all lines are verified below.
KEYWORD_RAW="YEAH KANCHI
YEAH KANCHIY
YEAH KAHNCHI
YEAH KAHNCHIY
YEAH KUNCHI
YEAH KUNCHIY
YEAH KANCHHI
YEAH KAHNCHHI"
KEYWORD_TOKENS="▁YEAH ▁K AN CH I
▁YEAH ▁K AN CH I Y
▁YEAH ▁K A H N CH I
▁YEAH ▁K A H N CH I Y
▁YEAH ▁K UN CH I
▁YEAH ▁K UN CH I Y
▁YEAH ▁K AN CH H I
▁YEAH ▁K A H N CH H I"

if [ -d "$DEST/$MODEL" ]; then
  echo "  ✓ $MODEL already present — skipping"
  echo ""
  echo "Done. Model at: $DEST/$MODEL"
  echo "Build the app — project.yml bundles Resources/Models/kws/ into the app."
  exit 0
fi

echo "  ↓ $MODEL ($(awk -v n="$EXPECTED_SIZE" 'BEGIN { printf "%.1f MB", n / 1000000 }'))"
mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fL "$BASE_URL/$MODEL.tar.bz2" -o "$tmp/$MODEL.tar.bz2"

# REQUIRED-VERIFY at fetch time (see header): refuse on any mismatch.
actual_sha="$(shasum -a 256 "$tmp/$MODEL.tar.bz2" | awk '{print $1}')"
actual_size="$(stat -f%z "$tmp/$MODEL.tar.bz2")"
if [ "$actual_sha" != "$EXPECTED_SHA256" ]; then
  echo "  ✗ sha256 mismatch for $MODEL.tar.bz2" >&2
  echo "    expected: $EXPECTED_SHA256" >&2
  echo "    actual:   $actual_sha" >&2
  echo "    (download aborted — nothing was installed)" >&2
  exit 1
fi
if [ "$actual_size" != "$EXPECTED_SIZE" ]; then
  echo "  ✗ size mismatch for $MODEL.tar.bz2 (expected $EXPECTED_SIZE, got $actual_size)" >&2
  exit 1
fi

tar -xjf "$tmp/$MODEL.tar.bz2" -C "$tmp"

# Keep only the int8 onnx trio + tokens.txt + bpe.model (provenance for
# the sentencepiece re-encoding above). Strip the fp32 trio, test wavs,
# README, and the archive's own keyword samples — the bundle stays ~5 MB.
# (Names differ only by ".int8": encoder-epoch-12-avg-2-chunk-16-left-64
# .onnx vs ...-64.int8.onnx — delete non-int8, keep int8.)
keep="$tmp/$MODEL"
for f in "$keep"/*.onnx; do
  case "$f" in
    *.int8.onnx) ;;
    *) rm -f "$f" ;;
  esac
done
rm -rf "$keep"/test_wavs
rm -f "$keep"/README.md "$keep"/*.wav
int8_count="$(ls "$keep"/*.int8.onnx 2>/dev/null | wc -l | tr -d ' ')"
[ "$int8_count" -ge 3 ] || { echo "  ✗ expected ≥3 int8 onnx files, found $int8_count" >&2; exit 1; }

# Overwrite the archive's keyword samples with OUR single runtime line.
printf '%s\n' "$KEYWORD_TOKENS" > "$keep/keywords.txt"
printf '%s\n' "$KEYWORD_RAW" > "$keep/keywords_raw.txt"

# Verify every keyword token exists in the model's tokens.txt (token =
# first whitespace field per line). This is the same membership the C++
# runtime checks (EncodeKeywords → EncodeBase); catching it here means
# the first launch can never hit sherpa's "Cannot find ID for token"
# refusal. Pure text tools — no python/sentencepiece needed at fetch
# time (the ▁-tokens above were already validated against this exact
# archive on 2026-09-08).
tokens_file="$keep/tokens.txt"
missing=""
for tok in $KEYWORD_TOKENS; do
  if ! awk '{print $1}' "$tokens_file" | grep -qxF "$tok"; then
    missing="$missing $tok"
  fi
done
if [ -n "$missing" ]; then
  echo "  ✗ keyword tokens not in model tokens.txt:$missing" >&2
  exit 1
fi

mv "$keep" "$DEST/$MODEL"
echo "  ✓ $MODEL installed ($(du -sh "$DEST/$MODEL" | cut -f1))"
echo "  ✓ keywords.txt = '$KEYWORD_TOKENS' (all tokens verified in tokens.txt)"
echo "  ✓ sha256 $actual_sha"

echo ""
echo "Done. Model at: $DEST/$MODEL"
echo "Build the app — project.yml bundles Resources/Models/kws/ into the app."
