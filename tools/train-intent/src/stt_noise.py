"""Stage 2 — STT-noise injection (spec §9.2: "the step everyone skips").

The intent model consumes STT output at runtime: dropped particles,
misspelled names, merged words ("माइयालाई"), wrong script. Training on
clean text guarantees a distribution mismatch, so this stage round-trips
teacher utterances through:

    text → TTS (piper) → audio → the app's ACTUAL bundled Whisper → noisy text

and emits ADDITIONAL rows with the same labels but the noisy transcript as
the utterance. Both the clean and noised versions stay in the mixture
(60/25/15 targets are applied in build_dataset.py).

Resumable: reads data/teacher.jsonl, appends to data/noised.jsonl; ids
already noised are skipped. Id format: "{source_id}:noise{n}".

Requires: piper TTS + whisper.cpp (paths in config.yaml:stt_noise).

Throughput note (2026-09-06): the hf backend transcribes in batches of
BATCH clips per generate() call — per-clip generate calls were ~10×
slower (one forward pass per utterance, fixed per-call overhead).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from config import load_config, abs_path

BATCH = 32  # clips per hf generate() call


def synthesize(text: str, wav_path: Path, cfg: dict) -> None:
    """TTS one utterance to 16 kHz mono wav via piper — resolved from the
    venv next to the running interpreter so detached runs don't depend
    on PATH."""
    import sys
    # Resolution order: explicit config `stt_noise.piper_bin` (needed when
    # the launcher venv differs from the piper venv — the hf backend runs
    # under the TRAIN venv for CUDA, but piper lives in the train-intent
    # venv), then interpreter-relative, then PATH.
    configured = cfg.get("stt_noise.piper_bin")
    piper = (Path(str(configured)).expanduser() if configured
             else Path(sys.executable).parent / "piper")
    model = Path(str(cfg["stt_noise.tts_voice"]))
    if not model.is_absolute():
        model = Path(__file__).parent.parent / model
    subprocess.run(
        [str(piper), "--model", str(model), "--output_file", str(wav_path)],
        input=text.encode(), check=True,
    )


def transcribe_cli(wav_path: Path, cfg: dict) -> str:
    """CPU path: whisper-cli (whisper.cpp). NOTE: the server's build is
    GGML_CUDA=OFF, so this is CPU-only — fine for smoke tests, too slow
    for the full stage (~20k utterances)."""
    whisper_cpp = Path(str(cfg["stt_noise.whisper_cpp"])).expanduser()
    model = Path(str(cfg["stt_noise.whisper_model"])).expanduser()
    out = subprocess.run(
        [str(whisper_cpp), "-m", str(model), "-f", str(wav_path),
         "-l", "ne", "--no-timestamps", "-nt"],
        capture_output=True, check=True,
    )
    return out.stdout.decode().strip()


def make_hf_transcriber(cfg: dict):
    """GPU path (default): the SAME model as the shipped GGML bin, in its
    original HF form (checkpoints/finetune-medium-final — the GGML was
    exported from it), running on CUDA via transformers in the
    tools/train venv. WhisperKit is NOT involved — it is an Apple-only
    (CoreML/ANE) runtime and does not exist on Linux.
    IMPORTANT (monitor rule): never overlaps another GPU stage — the
    launcher sequences this after rung 6 exits."""
    import torch
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    model_dir = str(cfg["stt_noise.hf_model"])
    processor = WhisperProcessor.from_pretrained(model_dir)
    model = WhisperForConditionalGeneration.from_pretrained(
        model_dir, torch_dtype=torch.float16).cuda().eval()
    forced = processor.get_decoder_prompt_ids(language="ne", task="transcribe")

    def transcribe(wav_path: Path) -> str:
        import soundfile as sf
        audio, sr = sf.read(str(wav_path), dtype="float32")
        if sr != 16000:
            import scipy.signal as sps
            audio = sps.resample(audio, int(len(audio) * 16000 / sr))
        inputs = processor(audio, sampling_rate=16000, return_tensors="pt")
        with torch.no_grad():
            ids = model.generate(
                inputs.input_features.cuda().half(),
                forced_decoder_ids=forced, max_new_tokens=96)
        return processor.batch_decode(ids, skip_special_tokens=True)[0].strip()

    def transcribe_batch(wav_paths: list[Path]) -> list[str]:
        """One padded forward pass per batch — the feature extractor pads
        a list of arrays internally, so no manual collation needed."""
        import soundfile as sf
        audios = []
        for p in wav_paths:
            audio, sr = sf.read(str(p), dtype="float32")
            if sr != 16000:
                import scipy.signal as sps
                audio = sps.resample(audio, int(len(audio) * 16000 / sr))
            audios.append(audio)
        inputs = processor(audios, sampling_rate=16000, return_tensors="pt")
        with torch.no_grad():
            ids = model.generate(
                inputs.input_features.cuda().half(),
                forced_decoder_ids=forced, max_new_tokens=96)
        return [t.strip() for t in
                processor.batch_decode(ids, skip_special_tokens=True)]

    return transcribe, transcribe_batch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--backend", choices=["hf", "cli"], default="hf",
                        help="hf = GPU transformers (default, needs the GPU free); cli = CPU whisper-cli")
    args, cfg = load_config(parser)

    root = Path(__file__).parent.parent
    src_path = root / "data" / "teacher.jsonl"
    out_path = root / "data" / "noised.jsonl"

    done: set[str] = set()
    if out_path.exists():
        with open(out_path, encoding="utf-8") as f:
            done = {json.loads(line)["id"] for line in f if line.strip()}

    if args.backend == "hf":
        transcribe, transcribe_batch = make_hf_transcriber(cfg)
    else:
        transcribe = lambda wav: transcribe_cli(wav, cfg)  # noqa: E731
        transcribe_batch = None

    rows = [json.loads(line) for line in open(src_path, encoding="utf-8") if line.strip()]
    if args.limit:
        rows = rows[: args.limit]

    variants = int(cfg["stt_noise.variants_per_utterance"])
    pending = [(row, n) for row in rows for n in range(variants)
               if f"{row['id']}:noise{n}" not in done]
    skipped = len(rows) * variants - len(pending)
    written = failed = 0
    with open(out_path, "a", encoding="utf-8") as out, tempfile.TemporaryDirectory() as tmp:
        for bi in range(0, len(pending), BATCH):
            chunk = pending[bi:bi + BATCH]
            wavs: list[Path] = []
            metas: list[tuple[dict, str]] = []
            from concurrent.futures import ThreadPoolExecutor

            def synth_one(row_n: tuple[dict, int]) -> tuple[Path, dict, str] | None:
                row, n = row_n
                nid = f"{row['id']}:noise{n}"
                wav = Path(tmp) / f"u{bi}_{n}.wav"
                try:
                    synthesize(row["utterance"], wav, cfg)
                    return wav, row, nid
                except Exception as e:  # noqa: BLE001
                    print(f"[stt_noise] {nid} synth failed: {e} — continuing")
                    return None
            with ThreadPoolExecutor(max_workers=8) as pool:
                for result in pool.map(synth_one, chunk):
                    if result is None:
                        failed += 1
                        continue
                    wav, row, nid = result
                    wavs.append(wav)
                    metas.append((row, nid))
            if not wavs:
                continue
            try:
                noisies = (transcribe_batch(wavs) if transcribe_batch is not None
                           else [transcribe(w) for w in wavs])
            except Exception as e:  # noqa: BLE001
                failed += len(wavs)
                print(f"[stt_noise] batch failed: {e} — continuing")
                continue
            for (row, nid), noisy in zip(metas, noisies):
                if not noisy or noisy == row["utterance"]:
                    continue  # identical round-trip teaches nothing
                new_row = dict(row)
                new_row["id"] = nid
                new_row["clean_utterance"] = row["utterance"]
                new_row["utterance"] = noisy
                new_row["source"] = f"stt_noise:{row.get('register', 'unknown')}"
                out.write(json.dumps(new_row, ensure_ascii=False) + "\n")
                done.add(nid)
                written += 1
            out.flush()
            print(f"[stt_noise] {min(bi + BATCH, len(pending))}/{len(pending)} "
                  f"pending, {written} noised")
    print(f"[stt_noise] done: {written} written, {skipped} skipped, {failed} failed → {out_path}")


if __name__ == "__main__":
    main()
