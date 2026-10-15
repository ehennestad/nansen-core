"""The run journal: which methods have completed on which entities.

Every time a method completes, in the queue or in the foreground, one line per entity is appended to
runs/<entityType>.runs.jsonl in the project: a nansen.run record. The file is only appended to, in one
write per run, so workers in other threads or processes (or MATLAB) can add to it at the same time. A
pipeline step is done for an entity once its method has completed on it; that is what the progress of
an entity's pipeline is made of. nansen.internal.runs does the same in MATLAB.
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path
from typing import Any, Dict, Iterable, Optional, Tuple

from .documents import check_document
from .schemas import current_version

KeyId = Tuple[Tuple[str, Any], ...]


def key_id(key: Dict[str, Any]) -> KeyId:
    """A hashable form of an entity key, whatever order its columns are in."""
    return tuple(sorted(key.items()))


def runs_path(folder: Path, entity_type: str) -> Path:
    return Path(folder) / "runs" / f"{entity_type}.runs.jsonl"


def record(folder: Path, method_id: str, method_version: str, entities: Iterable[Any],
           task_id: Optional[str] = None) -> None:
    """Append that the method completed on each of the entities."""
    finished = dt.datetime.now().isoformat(timespec="seconds")
    lines: Dict[str, list] = {}
    for entity in entities:
        line = {"schemaType": "nansen.run", "schemaVersion": current_version("nansen.run"),
                "method": {"id": method_id, "version": method_version}, "key": dict(entity.key),
                "finishedAt": finished}
        if task_id:
            line["task"] = task_id
        if not lines:  # every line is built the same way
            check_document(line, "nansen.run")
        lines.setdefault(entity.entity_type, []).append(json.dumps(line, ensure_ascii=False) + "\n")
    for entity_type, text in lines.items():
        path = runs_path(folder, entity_type)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write("".join(text))  # one write: lines from other writers do not interleave with these


def completed(folder: Path, entity_type: str) -> Dict[KeyId, Dict[str, str]]:
    """For each entity key, the methods that completed on it and when they last did."""
    path = runs_path(folder, entity_type)
    done: Dict[KeyId, Dict[str, str]] = {}
    if not path.is_file():
        return done
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                run = json.loads(line)
                if run.get("schemaType") != "nansen.run":
                    continue
                methods = done.setdefault(key_id(run["key"]), {})
                methods[run["method"]["id"]] = max(methods.get(run["method"]["id"], ""), run["finishedAt"])
            except (ValueError, KeyError, TypeError, AttributeError):
                continue  # a line cut short, or not a run
    return done
