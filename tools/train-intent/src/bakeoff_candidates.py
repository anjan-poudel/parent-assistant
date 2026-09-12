"""T-033 candidate registry + Hugging Face licence/access probe.

Produces the licence-evidence table required by the spike DoD: for every
candidate, licence name, source URL, access conditions (gated/ungated,
account requirement), date checked and revision SHA.

Nothing here is evidence of Nepali performance — the probe only answers
"may this checkpoint legally ship in an App Store / Play Store binary?".

Usage:
    python src/bakeoff_candidates.py --out ../t033-evidence/licence_probe.json

The HF token is read from HF_TOKEN or ~/.cache/huggingface/token and is
never printed (NFR-016: secrets never reach logs).
"""
from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HF_API = "https://huggingface.co/api/models/"
HF_RESOLVE = "https://huggingface.co/{repo}/resolve/{sha}/{path}"

# C1..C4 from the proposal doc; every field here is a hypothesis, verified live.
CANDIDATES = [
    {
        "id": "C1",
        "repo": "ai4bharat/IndicBERT-v3-270M",
        "family": "bidirectional Gemma-3 270M",
        "proposal_role": "proposal's #1 base model",
    },
    {
        "id": "C2",
        "repo": "jhu-clsp/mmBERT-small",
        "family": "ModernBERT (RoPE, GLU, Flash Attention 2)",
        "proposal_role": "proposal's production student candidate",
    },
    {
        "id": "C3",
        "repo": "cartesinus/multilingual_minilm-amazon-massive-intent",
        "family": "XLM-R MiniLM (MASSIVE-fine-tuned)",
        "proposal_role": "proposal's teacher/baseline",
    },
    {
        "id": "C4",
        "repo": "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
        "family": "XLM-R MiniLM sentence encoder (SetFit base)",
        "proposal_role": "SetFit variant proposed by this spike",
    },
]


def _token() -> str:
    env = __import__("os").environ.get("HF_TOKEN", "")
    if env:
        return env
    p = Path.home() / ".cache" / "huggingface" / "token"
    return p.read_text().strip() if p.exists() else ""


def _get(url: str, token: str = "", max_bytes: int | None = None) -> tuple[int, bytes]:
    """HTTP GET. `max_bytes` sends a Range header and reads one byte only —
    access checks must not download a 500 MB weight file."""
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if max_bytes is not None:
        req.add_header("Range", f"bytes=0-{max_bytes - 1}")
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            body = r.read(max_bytes) if max_bytes is not None else r.read()
            return r.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # network failure is itself evidence
        return 0, str(e).encode()


def probe(c: dict, token: str) -> dict:
    """One candidate's live access evidence, timestamped."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out = {
        "id": c["id"],
        "repo": c["repo"],
        "family": c["family"],
        "proposal_role": c["proposal_role"],
        "checked_utc": now,
        "model_page": f"https://huggingface.co/{c['repo']}",
    }
    status, body = _get(HF_API + c["repo"], token)
    out["api_status"] = status
    if status == 200:
        d = json.loads(body)
        out["sha"] = d.get("sha")
        out["gated"] = d.get("gated")
        out["private"] = d.get("private")
        out["last_modified"] = d.get("lastModified")
        out["tags"] = d.get("tags", [])
        out["license_tag"] = next(
            (t.split(":", 1)[1] for t in d.get("tags", []) if t.startswith("license:")), None)
        out["files"] = [s["rfilename"] for s in d.get("siblings", [])]
    sha = out.get("sha") or "main"
    # Can the project actually fetch the weights with the project token?
    for path in ("config.json", "model.safetensors", "pytorch_model.bin", "README.md"):
        st, _ = _get(HF_RESOLVE.format(repo=c["repo"], sha=sha, path=path), token,
                     max_bytes=1)
        out[f"fetch_{path.replace('.', '_')}"] = st
    # Model card licence statement (indirect evidence; recorded verbatim).
    st, card = _get(HF_RESOLVE.format(repo=c["repo"], sha=sha, path="README.md"), token)
    if st == 200:
        text = card.decode("utf-8", "replace")
        lines = [ln.strip() for ln in text.splitlines() if "licen" in ln.lower()]
        out["card_license_lines"] = lines[:6]
        out["has_license_file"] = any(f.lower().startswith("license") for f in out.get("files", []))
    out["has_license_file"] = any(f.lower().startswith(("license", "licence"))
                                  for f in out.get("files", []))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="licence_probe.json")
    ap.add_argument("--token-source", default="auto",
                    help="auto (HF_TOKEN then ~/.cache/huggingface/token) or none")
    args = ap.parse_args()

    token = "" if args.token_source == "none" else _token()
    results = []
    for c in CANDIDATES:
        print(f"[probe] {c['id']} {c['repo']} ...", flush=True)
        results.append(probe(c, token))
    Path(args.out).write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print(f"wrote {args.out} ({len(results)} candidates); authenticated probe: {bool(token)}")
    for r in results:
        print(f"  {r['id']} {r['repo']}: gated={r.get('gated')} "
              f"license_tag={r.get('license_tag')} sha={(r.get('sha') or '')[:12]} "
              f"config={r.get('fetch_config_json')} weights="
              f"{r.get('fetch_model_safetensors')}/{r.get('fetch_pytorch_model_bin')}")


if __name__ == "__main__":
    main()
