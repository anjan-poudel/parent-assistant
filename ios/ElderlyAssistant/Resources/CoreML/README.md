# Bundled CoreML encoders (Whisper ANE acceleration)

Drop `*-encoder.mlmodelc/` directories here to ship them with the app.
See `docs/whisper-coreml-acceleration-plan.md` for the full pipeline.

## What lives here

XcodeGen adds `.mlmodelc` bundles found under `ElderlyAssistant/Resources/`
to the app target as bundle resources. At install time,
`ModelStore.finalize(_:)` calls `installBundledCoreMLEncoder(for:)`, which
copies the resource next to the ggml `.bin` on disk. `whisper.cpp` then
auto-detects it and runs the encoder on the Neural Engine (ANE) instead
of the CPU — roughly 3–5× faster on iPhone.

## Which files this app looks for

The lookup key is the `coreMLEncoderBundledName` field on each
`ModelCatalogEntry` (in `Services/ModelStore/ModelCatalog.swift`).

Currently expected:

| Bundle resource | For model |
|---|---|
| `ggml-small-q5_1-encoder.mlmodelc/`      | `whisper-small-multilingual-q5_1` |
| `whisper-large-v3-nepali-ggml-encoder.mlmodelc/` | `whisper-large-v3-nepali-ggml` |

The resource **name** (before `.mlmodelc`) must match exactly — that's the
`(<ggml-file-stripped-of-.bin>-encoder)` convention `whisper.cpp` uses to
locate the sibling directory once the model is on disk.

Missing files are fine: transcription falls back to CPU with a
`coreml_encoder_not_bundled` observability event and no user-visible
error.

## How to generate the `.mlmodelc`

On a Mac (not iOS):

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install ane_transformers openai-whisper coremltools

git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
./models/generate-coreml-model.sh small          # ~5 min

# Produces: models/ggml-small-encoder.mlmodelc/
# Rename to match our catalog filename convention:
mv models/ggml-small-encoder.mlmodelc \
   models/ggml-small-q5_1-encoder.mlmodelc

# Move it here
cp -R models/ggml-small-q5_1-encoder.mlmodelc \
   <this-repo>/ios/ElderlyAssistant/Resources/CoreML/
```

Then rebuild (`./build.sh build`). First transcription after install
pays a one-time ANE compile (~10–30 s for small); subsequent transcriptions
should land at ~1–3 s per 5 s utterance on iPhone 12.

## Git

`.mlmodelc` directories are large binary blobs — either git-lfs them or
add them to `.gitignore` and ship via CI. The default expectation is
gitignore; this README stays checked in as the marker so the directory
survives an empty clone.
