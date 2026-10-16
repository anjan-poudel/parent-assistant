# TG-31: Write Seam and Coordinator Integration

> **Jira Epic:** Write Seam and Coordinator Integration

## Description
Builds the system-contact write seam (confined photo writer with read-back byte equality), wires the release log-safety gate to the feature's source roots, and integrates identity into the coordinator: verified-link refresh with generation guards, face identity/caching, and the link/unlink seam with the F3 copy-path pin.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-154](T-154-system-contact-photo-writer.md) | SystemContactPhotoWriter confined write + outcome mapping | L | T-145, T-148 | HIGH |
| [T-155](T-155-log-safety-feature-roots.md) | Release log-safety FEATURE_ROOTS registration and scan fixtures | S | T-149, T-151, T-154 | MEDIUM |
| [T-156](T-156-coordinator-identity-and-link-refresh.md) | Coordinator identity state and generation-guarded link refresh | M | T-149, T-151 | HIGH |
| [T-157](T-157-coordinator-face-identity.md) | Coordinator face identity, images and cache invalidation | M | T-156 | MEDIUM |
| [T-158](T-158-link-unlink-seam-and-missed-call-names.md) | Link/unlink seam, photo sync and link-aware call names | M | T-154, T-156 | HIGH |

## Group effort estimate
- Optimistic (full parallel): ~6 days
- Realistic (2 devs): ~7.5 days

## Notes
- F1 evidence lives here (T-154 source-level assertion + T-155 confinement scan); F3 pin lives here (T-158 unlink copy path).
- T-157 depends on T-156 because both units edit the same coordinator state surface; the dependency keeps them out of the same wave.
