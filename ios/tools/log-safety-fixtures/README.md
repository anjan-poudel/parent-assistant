# Log-safety gate fixtures (T-028 / AM-5)

These trees are the fixture suite for `../check-release-log-safety.py`. They are **not compiled**
— nothing under `ios/tools/` is in XcodeGen's source globs — and they are never shipped.

Layout: `log-safety-fixtures/<rule-id>/positive/ElderlyAssistant/…` must make the gate fail while
naming `<rule-id>`; `log-safety-fixtures/<rule-id>/negative/ElderlyAssistant/…` must make it pass.
A case may carry an `arguments` file whose whitespace-separated tokens are appended to the engine
invocation, with `{fixture}` expanded to the case directory (used by `engine-file-missing` and
`allow-list-unreadable` to point the engine at a fixture-local tree or allow-list).

Run them:

    python3 tools/check-release-log-safety-fixtures.py            # every build, via the .sh gate
    python3 tools/check-release-log-safety-fixtures.py --falsify  # also prove each rule is load-bearing

## Rules of the fixture suite

1. **A rule without a positive fixture is not a rule.** The runner reads the engine's own
   `--list-rules` registry and fails if any declared rule lacks a `positive` or `negative` tree, or
   if a directory exists that is not a declared rule (a typo would otherwise test nothing).
2. **A rule that fires only in company is not carrying its own weight.** `--falsify` re-runs each
   positive tree with `--disable-rule <rule>`; the tree must then *pass*. A positive fixture is
   therefore kept minimal and orthogonal: it trips its own rule and no other.
3. **Configuration matters and is part of the contract.** `feature-console-write` keeps the shipped
   Release framing (`#if DEBUG` is exempt); `feature-content-print` and the event-field rules are
   configuration-independent, because NFR-LCT-006 forbids content on a log surface in any build.
   The two are orthogonal by construction: rule 3 catches the Release bypass whatever it renders,
   rule 4 catches content where rule 3 cannot look. Their union — a Release-compiled content print —
   is caught by both and is deliberately *not* a single-rule fixture, since a fixture that trips two
   rules cannot falsify either on its own.

## Why this exists

`AM-5` required the gate's rule family to be extended and the design's invariant table corrected.
A gate whose rules are never exercised is indistinguishable from one that has stopped firing, and
the cheapest place to notice is the build: `check-release-log-safety.sh` runs this suite on every
invocation, next to the engine, and fails the build if a fixture stops behaving. Deleting a case to
get a green build is the one repair that is never available — fix the rule or fix the fixture.

Documented limits (a source-level check cannot follow indirection) live in the engine's docstring,
not here, and are part of the evidence rather than an omission from it.
