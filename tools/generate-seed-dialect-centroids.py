#!/usr/bin/env python3
"""Generate the bundled SEED dialect-centroid table (voice-personalisation P0, slice D).

Writes ios/ElderlyAssistant/Resources/DialectCentroids.json consumed by
DialectIdentifier (DialectCentroidTable). Status of the shipped artifact:
SEED-CENTROIDS — placeholder only, NOT calibrated.

Why seeds exist
---------------
The real pipeline (research accent-adaptation.md §4.4, §6 P0.2; plan slice D)
computes centroids server-side from a contracted per-cluster field corpus
(>=10 h per cluster) by mean-pooling `encoder_output_embeds` of the shipped
`whisperkit-ne-medium` artifact, unit-normalising each embedding, and
averaging per cluster. That corpus does not exist yet, and the classifier
must still ship with a structurally valid, honest table so the decode seam
and the pure-logic tests run end-to-end.

Seed honesty properties
-----------------------
- Centroids are unit vectors of deterministic pseudo-random direction
  (LCG over a fixed date seed) in 1024 dimensions. Cosine similarity between
  any real embedding and a random unit vector concentrates near 0, so the
  margin confidence stays ~0.5 — under the 0.6 gate — and classification
  honestly returns the `default` label. A seed table cannot mislabel a user.
- promptTokenIds are empty: no lexical bias claims are made without
  calibration. Decode biasing stays inert (label defaults) until a real
  table ships.
- generation.status == "SEED-CENTROIDS" in the artifact; the app treats any
  table as structurally valid but calibration-agnostic (the <60% confidence
  gate is what keeps seeds honest at classification time).

Regeneration
------------
    python3 tools/generate-seed-dialect-centroids.py          # seed → seed
    python3 tools/generate-seed-dialect-centroids.py --force  # overwrite anything

It refuses to overwrite a calibrated table (generation.status !=
SEED-CENTROIDS) without --force, so an accidental reseed cannot clobber real
centroids. The real calibration tooling replaces this script's data section
(the `clusters` block) while keeping the schema in DialectCentroidTable.
"""

import argparse
import json
import math
import os
import sys

EMBEDDING_DIMENSION = 1024
CONFIDENCE_GATE = 0.6
FORMAT_VERSION = 1
ENCODER = "whisperkit-ne-medium"  # ModelCatalog.whisperKitNepaliMedium
SEED = 20260908  # deterministic: table date
CLUSTERS = ["eastern", "doteli"]  # 2 seed clusters + `default` label

GENERATION_PATH = (
    "SEED-CENTROIDS (not calibrated). Real table: server-side pipeline "
    "mean-pooling whisperkit-ne-medium encoder_output_embeds over a contracted "
    "per-cluster field corpus (>=10 h per cluster, research "
    "accent-adaptation.md §4.4 + §6 P0.2), unit-normalised embeddings averaged "
    "per cluster; promptTokenIds = whisper BPE ids of the per-cluster prompt "
    "words (<=100 tokens). Regenerate seeds with "
    "tools/generate-seed-dialect-centroids.py."
)


def unit_vectors(dimension, count, seed):
    """Deterministic pseudo-random unit vectors (LCG), index-independent."""
    rng_state = seed
    vectors = []
    for _ in range(count):
        components = []
        for _ in range(dimension):
            rng_state = (1103515245 * rng_state + 12345) & 0x7FFFFFFF
            components.append((rng_state / 0x3FFFFFFF) * 2.0 - 1.0)
        norm = math.sqrt(sum(c * c for c in components)) or 1.0
        vectors.append([round(c / norm, 7) for c in components])
    return vectors


def main() -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = os.path.join(
        repo_root, "ios", "ElderlyAssistant", "Resources", "DialectCentroids.json"
    )

    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true",
                        help="overwrite even a calibrated table")
    args = parser.parse_args()

    if os.path.exists(out_path):
        with open(out_path, encoding="utf-8") as handle:
            existing = json.load(handle)
        if existing.get("generation", {}).get("status") != "SEED-CENTROIDS" and not args.force:
            print(f"refusing: {out_path} is not a SEED table; use --force to overwrite",
                  file=sys.stderr)
            return 1

    centroids = unit_vectors(EMBEDDING_DIMENSION, len(CLUSTERS), SEED)
    table = {
        "formatVersion": FORMAT_VERSION,
        "encoder": ENCODER,
        "embeddingDimension": EMBEDDING_DIMENSION,
        "similarityMetric": "cosine",
        "confidenceGate": CONFIDENCE_GATE,
        "generation": {
            "status": "SEED-CENTROIDS",
            "path": GENERATION_PATH,
            "date": None,
        },
        "clusters": [
            {
                "id": cluster_id,
                "centroid": centroid,
                "promptTokenIds": [],  # filled by calibration, never seeded
                "promptText": [],      # reference strings come with calibration
            }
            for cluster_id, centroid in zip(CLUSTERS, centroids)
        ],
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(table, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"wrote SEED table: {out_path} "
          f"({EMBEDDING_DIMENSION}-dim, {len(CLUSTERS)} clusters)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
