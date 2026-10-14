import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def test_core_keeps_no_global_state():
    result = subprocess.run([sys.executable, str(REPO / "tools" / "check_no_global_state.py")],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout


def test_matlab_runs_the_same_conformance_kinds_as_python():
    import re

    from nansen.conformance import KINDS

    text = (REPO / "matlab" / "+nansen" / "+conformance" / "listCases.m").read_text()
    kinds = re.search(r"for kind = \[(.*?)\]", text).group(1)
    assert tuple(re.findall(r'"([a-z]+)"', kinds)) == KINDS
    run_case = (REPO / "matlab" / "+nansen" / "+conformance" / "runCase.m").read_text()
    for kind in KINDS:
        assert f'case "{kind}"' in run_case, kind


def test_every_error_code_is_documented():
    import re

    root = Path(__file__).resolve().parents[2]
    documented = set()
    for page in ("docs/conventions.md", "docs/reference/protocol.md"):
        documented |= set(re.findall(r"^\| `([a-z-]+)` \|", (root / page).read_text(), re.M))
    used = set()
    for path in list((root / "python" / "src").rglob("*.py")) + list((root / "matlab").rglob("*.m")):
        used |= set(re.findall(r"(?:NansenError|throwError)\(\s*\"([a-z-]+)\"", path.read_text()))
    assert used - documented == set()
