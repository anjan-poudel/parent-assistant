# CLAUDE.md

## ai-sdd: Specification-Driven Development

This project uses ai-sdd. The framework runs under the hood — you do not need to
run any ai-sdd commands manually.

## How to use
- Type `/sdd-run` to execute the next workflow task.
- Answer clarifying questions and approve HIL gates as they appear.
- Type `/sdd-status` to check progress at any time.

## Working rules
- Never work in the main checkout. All task work (code, docs, specs) runs in a dedicated git worktree (branch `worktree-<slug>`), usually via a subagent. The main checkout is for integration commits and verification only.

## Project context
See `constitution.md` for project purpose, rules, standards, and the artifact manifest.
