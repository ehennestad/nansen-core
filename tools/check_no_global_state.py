"""Fail when the core keeps global state: the rule from docs/reference/project-layout.md.

MATLAB: no global or persistent variables, no preferences, no appdata on the
root object. Python: no global statements. Run from anywhere:
python tools/check_no_global_state.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

RULES = [
    ("matlab/+nansen", "*.m", re.compile(r"^\s*(global|persistent)\s"), "global or persistent variable"),
    ("matlab/+nansen", "*.m", re.compile(r"\b(getpref|setpref|addpref|rmpref|ispref)\s*\("), "MATLAB preference"),
    ("matlab/+nansen", "*.m", re.compile(r"\b(setappdata|getappdata)\s*\(\s*(0|groot)\b"), "appdata on the root object"),
    ("python/src/nansen", "*.py", re.compile(r"^\s*global\s"), "global statement"),
]


def main() -> int:
    problems = []
    for folder, pattern, regex, what in RULES:
        for path in sorted((REPO / folder).rglob(pattern)):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                code = line.split("%", 1)[0] if path.suffix == ".m" else line.split("#", 1)[0]
                if regex.search(code):
                    problems.append(f"{path.relative_to(REPO)}:{number}: {what}: {line.strip()}")
    for problem in problems:
        print(problem)
    print(f"{len(problems)} global-state problem(s)" if problems else "no global state")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
