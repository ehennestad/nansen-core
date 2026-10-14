from pathlib import Path

import pytest

from nansen.conformance import KINDS, run_case

ROOT = Path(__file__).resolve().parents[2] / "conformance"
CASES = [(kind, case) for kind in KINDS for case in sorted(p for p in (ROOT / kind).iterdir() if p.is_dir())]


@pytest.mark.parametrize("kind,case", CASES, ids=[f"{k}/{c.name}" for k, c in CASES])
def test_case(kind, case):
    result = run_case(kind, case)
    assert result.passed, result.detail


def test_every_case_has_a_description():
    import json

    for _, case in CASES:
        assert json.loads((case / "expected.json").read_text())["description"]
