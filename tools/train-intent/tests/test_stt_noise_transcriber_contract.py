"""T-036 stage-E2 contract test: the transcriber call site and both transcriber
callables must agree on arity.

`stt_noise.main()` binds `transcribe` to one of two callables — the inner
`transcribe` returned by `make_hf_transcriber` (hf backend) or the `lambda wav:
transcribe_cli(wav, cfg)` (cli backend). Commit f013382 added the hf backend
with a ONE-argument inner `transcribe` but left the call site passing `(wav,
cfg)`, so every row raised TypeError and the stage silently wrote 0 rows for
ten days. The failure is invisible in aggregate (the pass reports "0 written"
and exits 0), which is exactly why it is pinned here.

Read with `ast` rather than importing: `stt_noise` imports `yaml`, and this must
run on the server venv and on a bare checkout alike.
"""
from __future__ import annotations

import ast
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STT_NOISE = ROOT / "src" / "stt_noise.py"


def _parse() -> ast.Module:
    return ast.parse(STT_NOISE.read_text(encoding="utf-8"))


def _positional_arity(fn: ast.FunctionDef | ast.Lambda) -> int:
    return len(fn.args.args) + len(fn.args.posonlyargs)


def _callable_arities(tree: ast.Module) -> dict[str, int]:
    """Arity of every callable `main()` can bind to the name `transcribe`."""
    arities: dict[str, int] = {}

    hf = next(n for n in ast.walk(tree) if
              isinstance(n, ast.FunctionDef) and n.name == "make_hf_transcriber")
    inner = next(n for n in ast.walk(hf) if
                 isinstance(n, ast.FunctionDef) and n.name == "transcribe")
    arities["hf"] = _positional_arity(inner)

    main = next(n for n in ast.walk(tree) if
                isinstance(n, ast.FunctionDef) and n.name == "main")
    lambdas = [n for n in ast.walk(main) if isinstance(n, ast.Lambda)]
    arities["cli"] = _positional_arity(lambdas[0])
    return arities


def _call_site_arity(tree: ast.Module) -> int:
    """Positional arity of the `transcribe(...)` call inside main()."""
    calls = [n for n in ast.walk(tree)
             if isinstance(n, ast.Call)
             and isinstance(n.func, ast.Name) and n.func.id == "transcribe"]
    if len(calls) != 1:
        raise AssertionError(f"expected exactly 1 transcribe() call site, got {len(calls)}")
    return len(calls[0].args)


class TestTranscriberArityContract(unittest.TestCase):

    def test_call_site_matches_every_transcriber(self):
        tree = _parse()
        call_arity = _call_site_arity(tree)
        for backend, arity in _callable_arities(tree).items():
            with self.subTest(backend=backend):
                self.assertEqual(
                    call_arity, arity,
                    f"main() calls transcribe() with {call_arity} positional args "
                    f"but the {backend} transcriber takes {arity} — every row would "
                    f"raise TypeError and the stage would write 0 rows")

    def test_both_backends_take_a_single_wav(self):
        """Neither transcriber needs `cfg` — it is captured by closure in both
        branches (`make_hf_transcriber(cfg)` / the cli lambda)."""
        self.assertEqual(_callable_arities(_parse()), {"hf": 1, "cli": 1})


if __name__ == "__main__":
    unittest.main()
