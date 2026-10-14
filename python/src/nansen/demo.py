"""A demo project with a small two-photon dataset, for trying the app and for UI tests."""

from __future__ import annotations

import json
import random
from pathlib import Path

from .documents import PathLike
from .project import Project

SUBJECTS = {"m110": ["20250523-001", "20250523-002", "20250526-001", "20250602-001"],
            "m111": ["20250524-001", "20250527-001", "20250603-001"],
            "m112": ["20250525-001", "20250528-001", "20250528-002", "20250604-001", "20250611-001"],
            "m113": ["20250601-001", "20250608-001"]}

DATASET = {
    "schemaVersion": "0.1.0",
    "entityTypes": [
        {"name": "subject", "description": "An experimental animal", "isPrimary": True, "identifierRef": "subject_id"},
        {"name": "session", "description": "One two-photon imaging session", "identifierRef": "session_id"},
    ],
    "metadataDefinitions": {
        "subject_id": {"name": "subject_id", "title": "Subject", "dataType": "string", "ofEntity": "subject",
                       "validation": {"pattern": "^m\\d{3}$"}},
        "session_id": {"name": "session_id", "title": "Session", "dataType": "string", "ofEntity": "session",
                       "validation": {"pattern": "^m\\d{3}-\\d{8}-\\d{3}$"}},
        "session_date": {"name": "session_date", "title": "Date", "dataType": "date", "ofEntity": "session"},
        "session_time": {"name": "session_time", "title": "Start time", "dataType": "time", "ofEntity": "session"},
    },
    "dataLocations": [
        {
            "identifier": "raw", "displayName": "Raw two-photon data", "dataCategory": "raw", "access": "read",
            "sourceType": "filesystem",
            "filesystemSource": {
                "rootStoragePaths": [{"identifier": "local", "path": "data/raw"}],
                "entityLayout": [
                    {"name": "dates", "matchPattern": "^\\d{4}_\\d{2}_\\d{2}$"},
                    {"name": "sessions", "entityType": "session",
                     "matchPattern": "^\\d{4}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_\\d{2}_m\\d{3}-\\d{8}-\\d{3}$",
                     "filePatterns": [{"name": "two_photon_movie", "pattern": "\\.raw$", "isRequired": True, "cardinality": "one"},
                                      {"name": "acquisition_config", "pattern": "\\.ini$", "cardinality": "one"}]},
                ],
                "metadataMapping": [
                    {"metadataRef": "session_id", "extraction": {"method": "regex", "pattern": "_(m\\d{3}-\\d{8}-\\d{3})$", "entityLayoutLevel": "sessions"}},
                    {"metadataRef": "subject_id", "extraction": {"method": "regex", "pattern": "_(m\\d{3})-\\d{8}-\\d{3}$", "entityLayoutLevel": "sessions"}},
                    {"metadataRef": "session_date", "extraction": {"method": "substring", "pattern": ":", "valueFormat": "yyyy_MM_dd", "entityLayoutLevel": "dates"}},
                    {"metadataRef": "session_time", "extraction": {"method": "regex", "pattern": "^\\d{4}_\\d{2}_\\d{2}_(\\d{2}_\\d{2}_\\d{2})_", "valueFormat": "HH_mm_ss", "entityLayoutLevel": "sessions"}},
                ],
            },
        },
        {
            "identifier": "processed", "displayName": "Processed", "dataCategory": "processed", "access": "readwrite",
            "sourceType": "filesystem", "derivedFrom": ["raw"],
            "filesystemSource": {
                "rootStoragePaths": [{"identifier": "local", "path": "data/processed"}],
                "entityLayout": [
                    {"name": "subjects", "entityType": "subject", "pathComponentTemplate": "subject-{subject_id}"},
                    {"name": "sessions", "entityType": "session", "pathComponentTemplate": "session-{session_id}",
                     "filePatterns": [{"name": "motion_corrected", "pattern": "^{session_id}_motion_corrected\\.json$", "cardinality": "one"},
                                      {"name": "roi_signals", "pattern": "^{session_id}_roi_signals\\.json$", "cardinality": "one"}]},
                ],
                "metadataMapping": [
                    {"metadataRef": "subject_id", "extraction": {"method": "regex", "pattern": "^subject-(.+)$", "entityLayoutLevel": "subjects"}},
                    {"metadataRef": "session_id", "extraction": {"method": "regex", "pattern": "^session-(.+)$", "entityLayoutLevel": "sessions"}},
                ],
            },
        },
    ],
}


def create_demo(folder: PathLike, seed: int = 7) -> Project:
    """Write a demo dataset and project into an empty folder, scan it and fill the tables."""
    folder = Path(folder)
    if folder.exists() and any(folder.iterdir()):
        raise FileExistsError(f"{folder} is not empty")
    rng = random.Random(seed)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "dataset.dsm.json").write_text(json.dumps(DATASET, indent=2) + "\n")
    for subject, sessions in SUBJECTS.items():
        for number, session in enumerate(sessions):
            date = session[:8]
            day = f"{date[:4]}_{date[4:6]}_{date[6:]}"
            hour = 9 + number * 2
            raw = folder / "data" / "raw" / day / f"{day}_{hour:02d}_{rng.randint(0, 59):02d}_00_{subject}-{session}"
            raw.mkdir(parents=True, exist_ok=True)
            (raw / "rec.raw").write_bytes(bytes(rng.randint(2000, 20000)))
            if rng.random() < 0.8:
                (raw / "rec.ini").write_text("[scan]\nzoom=2\n")
            if number < len(sessions) - 1:  # the newest session of each subject is not processed yet
                processed = folder / "data" / "processed" / f"subject-{subject}" / f"session-{subject}-{session}"
                processed.mkdir(parents=True, exist_ok=True)
                (processed / f"{subject}-{session}_motion_corrected.json").write_text(
                    json.dumps({"shifts": [rng.random() for _ in range(5)]}))
    project = Project.create(folder, "TwoPhotonDemo", "Two-photon demo", dataset="dataset.dsm.json")
    project.document["description"] = "A small two-photon dataset: raw recordings, some processed, for trying NANSEN."
    project._check_and_save()
    project.add_module("core")
    project.add_entity_type("subject", fragments=["core.notes"], title="Subjects")
    project.add_entity_type("session", fragments=["core.notes", "core.file_stats"], title="Sessions")
    for name, location, pattern, file_name, adapter in [
        ("movie", "raw", "two_photon_movie", None, "text"),
        ("motion_corrected", "processed", "motion_corrected", "{session_id}_motion_corrected.json", "json"),
        ("roi_signals", "processed", "roi_signals", "{session_id}_roi_signals.json", "json"),
    ]:
        document = {"schemaType": "nansen.dataVariable", "schemaVersion": "0.1.0", "name": name, "entityType": "session",
                    "dataLocation": location, "filePattern": pattern, "fileAdapter": adapter}
        if file_name:
            document["fileName"] = file_name
        project.add_data_variable(document)
    project.scan()
    project.sync("subject")
    project.sync("session")
    sessions = project.table("session")
    notes = ["Good imaging", "Some motion", "", "Bleaching after 20 min", "", "Check focus"]
    for row in sessions.rows:
        key = {"subject_id": row["subject_id"], "session_id": row["session_id"]}
        sessions.update(key, description=rng.choice(notes) or None, ignore=rng.random() < 0.12)
    sessions.write()
    project.update_fragment("session", "core.file_stats")
    project.save_preset("core.wait", "quick", {"seconds": 1, "steps": 5}, "One second per entity")
    return Project.open(folder)
