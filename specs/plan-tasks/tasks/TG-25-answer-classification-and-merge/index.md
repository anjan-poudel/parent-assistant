# TG-25: Answer Classification and Merge

> **Jira Epic:** Answer Classification and Merge

## Description

The deterministic answer-turn brain: keyword-rule provenance and near-matches
(C-MTC-06), the classifier plus merge ladder with the B1–B7 barge-in predicates
(C-MTC-02), and did-you-mean candidate assembly (C-MTC-03). All three are pure,
model-free units against the types from TG-24; they carry the capture ladder
(design-l2 §11), the V1–V14 vectors and the M-5 totality guarantee.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-130](T-130-keyword-intent-rule-provenance.md) | Keyword-rule provenance, near-matches and markers | M (2.5 d) | — | HIGH |
| [T-131](T-131-dialogue-answer-path-classification.md) | Answer path: classification, merge and barge-in | L (4 d) | T-125, T-126, T-128, T-130 | HIGH |
| [T-132](T-132-dialogue-candidate-builder.md) | Candidate assembly for did-you-mean probes | S (1 d) | T-125, T-126, T-130 | MEDIUM |

## Group effort estimate

- Optimistic (full parallel): 5 days
- Realistic (2 developers): 6 days
