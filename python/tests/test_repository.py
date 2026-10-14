import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def test_core_keeps_no_global_state():
    result = subprocess.run([sys.executable, str(REPO / "tools" / "check_no_global_state.py")],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout


def test_every_matlab_conformance_kind_matches_python():
    from nansen.conformance import KINDS

    text = (REPO / "matlab" / "+nansen" / "+conformance" / "listCases.m").read_text()
    assert '["documents", "tables", "projects"]' in text
    assert KINDS == ("documents", "tables", "projects")
