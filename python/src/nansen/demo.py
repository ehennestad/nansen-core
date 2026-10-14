"""A demo project with a small two-photon dataset, for trying the app and for UI tests.

What is built is described in the core module's demo/ folder (demo.json and dataset.dsm.json), which
MATLAB's nansen.demo.create reads too.
"""

from __future__ import annotations

import json
import random
import shutil
from pathlib import Path

from .documents import PathLike
from .errors import NansenError
from .modules import built_in_modules_dir
from .project import Project


def demo_dir() -> Path:
    folder = built_in_modules_dir()
    if folder is None:
        raise FileNotFoundError("the built-in modules (with core/demo) were not found")
    return folder / "core" / "demo"


def create_demo(folder: PathLike, seed: int = 7) -> Project:
    """Write a demo dataset and project into an empty folder, scan it and fill the tables."""
    folder = Path(folder)
    if folder.exists() and any(folder.iterdir()):
        raise NansenError("folder-not-empty", f"{folder} is not empty")
    plan = json.loads((demo_dir() / "demo.json").read_text(encoding="utf-8"))
    rng = random.Random(seed)
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(demo_dir() / "dataset.dsm.json", folder / "dataset.dsm.json")
    for subject, sessions in plan["subjects"].items():
        for number, session in enumerate(sessions):
            date = session[:8]
            day = f"{date[:4]}_{date[4:6]}_{date[6:]}"
            hour = 9 + number * 2
            raw = folder / "data" / "raw" / day / f"{day}_{hour:02d}_{rng.randint(0, 59):02d}_00_{subject}-{session}"
            raw.mkdir(parents=True, exist_ok=True)
            (raw / "rec.raw").write_bytes(bytes(rng.randint(2000, 20000)))
            if rng.random() < plan["configChance"]:
                (raw / "rec.ini").write_text("[scan]\nzoom=2\n")
            if number < len(sessions) - 1:  # the newest session of each subject is not processed yet
                processed = folder / "data" / "processed" / f"subject-{subject}" / f"session-{subject}-{session}"
                processed.mkdir(parents=True, exist_ok=True)
                (processed / f"{subject}-{session}_motion_corrected.json").write_text(
                    json.dumps({"shifts": [rng.random() for _ in range(5)]}))
    info = plan["project"]
    project = Project.create(folder, info["name"], info["title"], dataset="dataset.dsm.json",
                             description=info["description"])
    project.add_module("core")
    for entity_type in plan["entityTypes"]:
        project.add_entity_type(entity_type["name"], fragments=entity_type["fragments"], title=entity_type["title"])
    for document in plan["dataVariables"]:
        project.add_data_variable(document)
    project.scan()
    for entity_type in plan["entityTypes"]:
        project.sync(entity_type["name"])
    sessions = project.table("session")
    for row in sessions.rows:
        key = {"subject_id": row["subject_id"], "session_id": row["session_id"]}
        sessions.update(key, description=rng.choice(plan["notes"]) or None, ignore=rng.random() < plan["ignoreChance"])
    sessions.write()
    project.update_fragment("session", "core.file_stats")
    for preset in plan["presets"]:
        project.save_preset(preset["methodId"], preset["name"], preset["values"], preset["description"])
    return Project.open(folder)
