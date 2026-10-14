"""nansen: validate documents and run the conformance cases."""

from __future__ import annotations

import argparse
import sys
from typing import List, Optional

from .conformance import run_cases
from .documents import read_document
from .errors import NansenError
from .tables import EntityTable


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="nansen")
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate documents (a table sidecar also checks its CSV)")
    validate.add_argument("paths", nargs="+")
    conformance = commands.add_parser("conformance", help="run the conformance cases")
    conformance.add_argument("root", nargs="?", default=None)
    conformance.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    if args.command == "validate":
        failed = 0
        for path in args.paths:
            try:
                document = read_document(path)
                if document["schemaType"] == "nansen.table":
                    EntityTable.read(path)
                print(f"ok    {path}")
            except NansenError as error:
                failed += 1
                print(f"FAIL  {path}: {error}")
        return 1 if failed else 0

    results = run_cases(args.root)
    failed = [r for r in results if not r.passed]
    for result in results:
        if args.verbose or not result.passed:
            status = "ok  " if result.passed else "FAIL"
            print(f"{status}  {result.kind}/{result.name}" + (f": {result.detail}" if result.detail else ""))
    print(f"{len(results) - len(failed)} of {len(results)} cases passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
