# T-121: Release log-safety gate FEATURE_ROOTS extension

## Metadata
- **Group:** [TG-23 — Release Gates, Security Evidence and Device Validation](index.md)
- **Component:** C-SP-13 release log-safety gate (`ios/tools/check-release-log-safety.sh`)
- **Agent:** dev
- **Effort:** S
- **Risk:** HIGH
- **Depends on:** [T-107](../TG-18-spotify-tool-and-deep-link-hardening/T-107-deep-link-grammar-and-hardening.md), [T-110](../TG-19-account-linking-credential-store-and-session/T-110-spotify-account-session.md), [T-118](../TG-22-plugin-wiring-settings-and-localisation/T-118-spotify-plugin-and-prompt-fragment.md)
- **Blocks:** [T-123](T-123-security-evidence-bundle.md), [T-124](T-124-device-validation-protocol.md)
- **Requirements:** [NFR-SP-002](../../../../define-requirements/NFR/NFR-SP-002-log-safety.md), [NFR-SP-011](../../../../define-requirements/NFR/NFR-SP-011-compliance-and-release-gates.md)

## Description
Extends the binding release log-safety gate with the feature roots so the new log surfaces are build-blocking, not report-only: `Services/Spotify/`, `Voice/SpotifyTool.swift` and `Plugins/SpotifyPlugin.swift` join `FEATURE_ROOTS`. The gate exits 0 on a clean tree and fails on a planted violation in a new root.

## Acceptance criteria

```gherkin
Feature: Release log-safety gate coverage

  Scenario: The gate covers the new roots and exits 0
    Given the feature's logging paths exist
    When the gate runs over the worktree
    Then it inspects the new Spotify tool, store, session and plugin paths
    And it exits 0

  Scenario: A planted violation in a new root fails the gate
    Given a fixture file under a new feature root that logs a query or credential value
    When the gate runs
    Then it fails with a non-zero exit
    And the failing file and rule are named in the output

  Scenario: Rule scope matches the verified role model
    Given the gate's rule scoping (rule 1 judged for every file, rule 2 for engine files, rules 3 to 6 for feature roots)
    When the gate processes the new roots
    Then each rule is applied at its correct scope
    And the per-rule fixtures demonstrate both pass and fail
```

## Implementation notes
- File: `ios/tools/check-release-log-safety.sh` (wired into `ios/build.sh`): add the three roots to `FEATURE_ROOTS` exactly as the design's edit list specifies.
- C-2 (documentation-only condition, no code change): the design's §20 sentence about rule scope is corrected to the verified model — rule 1 all files, rule 2 engine files, rules 3 to 6 feature roots. This task implements the correct scoping; there is no other action for C-2.
- The gate is binding for release: this task also confirms `ios/build.sh` invokes it and fails the build on non-zero exit.
- Per-rule fixtures mirror the shipped fixture pattern; the planted-violation test is security evidence for obligation 6 and is packaged by T-123.
- No exemption lists additions for the new roots.

## Definition of done
- [ ] Code reviewed and merged
- [ ] All Gherkin scenarios covered by automated tests/fixtures (per-rule pass and fail)
- [ ] `ios/build.sh` release path fails on a planted violation and passes on the clean tree
- [ ] Gate output names file and rule on failure
- [ ] No PII in logs — demonstrated by the gate, not asserted here
