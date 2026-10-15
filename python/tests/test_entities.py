"""Projects with a dataset: scanning a real folder, joining, syncing, generating paths."""

import json
from pathlib import Path

import pytest

from nansen import NansenError, Project

DATASET = json.loads((Path(__file__).resolve().parents[2] / "testdata" / "entities-dataset.dsm.json").read_text())


@pytest.fixture
def project(tmp_path):
    (tmp_path / "dataset.dsm.json").write_text(json.dumps(DATASET))
    for path in ["sub-m1/ses-m1-001/movie.tif", "sub-m1/ses-m1-002/movie.tif", "sub-m2/ses-m2-001/notes.txt"]:
        target = tmp_path / "data" / "raw" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("x")
    (tmp_path / "data" / "processed" / "m1" / "m1-001").mkdir(parents=True)
    project = Project.create(tmp_path, "Pilot", dataset="dataset.dsm.json")
    project.add_entity_type("subject")
    project.add_entity_type("session")
    return project


def test_key_comes_from_the_dataset(project):
    assert project.table("subject").spec.key == ["subject_id"]
    assert project.table("session").spec.key == ["subject_id", "session_id"]


def test_scan_reads_the_folders_and_caches(project):
    scan = project.scan()
    assert project.scan_path.is_file()
    assert {r["identity"]["session_id"] for r in scan.records_of("session")} == {"m1-001", "m1-002", "m2-001"}
    roots = {(r["dataLocation"], r["rootStoragePath"]): r["available"] for r in scan.roots}
    assert roots == {("raw", "here"): True, ("processed", "here"): True}
    assert project.last_scan().records == scan.records


def test_environment_selects_roots(tmp_path, project):
    lab = Project.open(project.folder, environment="lab")
    assert [(r.data_location, r.available) for r in lab.dataset.roots()] == [("raw", False)]
    assert lab.scan(save=False).records == []


def test_entities_join_and_sync(project):
    project.scan()
    sessions = project.entities("session")
    assert [e.in_table for e in sessions] == [False, False, False]
    m1 = project.entity("session", {"session_id": "m1-001"})
    assert m1.location("processed")["paths"] == ["m1/m1-001/"]
    assert m1.files("raw", "movie") == ["sub-m1/ses-m1-001/movie.tif"]
    assert m1.attributes["session_number"] == 1
    added = project.sync("session")
    assert added == [{"subject_id": "m1", "session_id": "m1-001"}, {"subject_id": "m1", "session_id": "m1-002"},
                     {"subject_id": "m2", "session_id": "m2-001"}]
    assert all(e.in_table and e.in_store for e in project.entities("session"))
    assert project.sync("session") == []


def test_rows_without_records_are_kept(project):
    project.scan()
    project.sync("subject")
    table = project.table("subject")
    table.add({"subject_id": "m9"})
    table.write()
    ghost = project.entity("subject", {"subject_id": "m9"})
    assert ghost.in_table and not ghost.in_store


def test_generate_path(project):
    assert project.dataset.generate_path("processed", "session", {"subject_id": "m2", "session_id": "m2-001"}) == "m2/m2-001/"
    with pytest.raises(NansenError) as error:
        project.dataset.generate_path("raw", "session", {"subject_id": "m2", "session_id": "m2-001"})
    assert error.value.code == "generation-failed"


def test_folders_matched_to_entities_by_hand(project):
    raw = project.folder / "data" / "raw"
    (raw / "sub-m1" / "odd").mkdir()
    (raw / "sub-m1" / "odd" / "movie.tif").write_text("x")
    (raw / "Mouse2" / "ses-m2-009").mkdir(parents=True)
    (raw / "Mouse2" / "ses-m2-009" / "movie.tif").write_text("x")
    scan = project.scan()
    assert sorted(u["path"] for u in scan.unmatched) == ["Mouse2/", "sub-m1/odd/"]
    dataset = project.dataset
    assert dataset.suggested_key("raw", "here", "sub-m1/odd/") == ("session", {"subject_id": "m1", "session_id": None})
    assert dataset.suggested_key("raw", "here", "Mouse2/") == ("subject", {"subject_id": None})
    assert dataset.suggested_key("raw", "here", "sub-m1/odd") == (None, None)  # a file where a folder is expected

    assignment = project.assign_entry("raw", "sub-m1\\odd", {"subject_id": "m1", "session_id": " m1-002 "})
    assert assignment == {"dataLocation": "raw", "path": "sub-m1/odd/", "entityType": "session",
                          "key": {"subject_id": "m1", "session_id": "m1-002"}}
    project.assign_entry("raw", "Mouse2/", {"subject_id": "m2"})
    assert [a["path"] for a in project.assignments()] == ["sub-m1/odd/", "Mouse2/"]
    scan = project.scan()
    assert scan.unmatched == []
    # a folder given to a session found elsewhere: one more folder of it, with its files
    m1_002 = project.entity("session", {"session_id": "m1-002"})
    assert m1_002.location("raw")["paths"] == ["sub-m1/odd/", "sub-m1/ses-m1-002/"]
    assert m1_002.files("raw", "movie") == ["sub-m1/odd/movie.tif", "sub-m1/ses-m1-002/movie.tif"]
    assert "duplicate-entity" in {i["code"] for i in m1_002.issues}
    # a subject's folder: what is below it is walked as usual, with the subject as its parent
    m2_009 = project.entity("session", {"session_id": "m2-009"})
    assert m2_009.key == {"subject_id": "m2", "session_id": "m2-009"}
    assert m2_009.location("raw")["paths"] == ["Mouse2/ses-m2-009/"]
    assert m2_009.attributes["session_number"] == 9
    assert project.entity("subject", {"subject_id": "m2"}).location("raw")["paths"] == ["Mouse2/", "sub-m2/"]
    assert len(project.entities("session")) == 4

    # assigned anew, in its place: a session not found anywhere else
    project.assign_entry("raw", "sub-m1/odd/", {"subject_id": "m1", "session_id": "m1-007"})
    assert [a["key"].get("session_id") for a in project.assignments()] == ["m1-007", None]
    project.scan()
    assert project.entity("session", {"session_id": "m1-007"}).location("raw")["paths"] == ["sub-m1/odd/"]
    assert project.entity("session", {"session_id": "m1-002"}).location("raw")["paths"] == ["sub-m1/ses-m1-002/"]

    removed = project.unassign_entry("raw", "sub-m1/odd")
    assert removed["key"]["session_id"] == "m1-007"
    with pytest.raises(NansenError) as error:
        project.unassign_entry("raw", "sub-m1/odd/")
    assert error.value.code == "unknown-assignment"
    assert [u["path"] for u in project.scan().unmatched] == ["sub-m1/odd/"]


def test_matching_by_hand_is_checked(project):
    for location, path, key, code in [
        ("raw", "sub-m1/odd/", {"subject_id": "m1"}, "invalid-params"),                           # a column missing
        ("raw", "sub-m1/odd/", {"subject_id": "m1", "session_id": ""}, "invalid-params"),         # an empty value
        ("raw", "sub-m1/odd/", {"subject_id": "m1", "session_id": 3}, "invalid-params"),          # not a text
        ("raw", "sub-m1/odd/x/", {"subject_id": "m1", "session_id": "x"}, "invalid-params"),      # below the levels
        ("raw", "../odd/", {"subject_id": "m1"}, "invalid-params"),
        ("lab", "sub-m1/", {"subject_id": "m1"}, "unknown-location"),
    ]:
        with pytest.raises(NansenError) as error:
            project.assign_entry(location, path, key)
        assert error.value.code == code, (path, key)
    assert project.assignments() == []
    # an assignment the config no longer fits (another level's entity type) is left out of scans
    from nansen.documents import write_json

    write_json(project.assignments_path, {"schemaType": "nansen.assignments", "schemaVersion": "0.1.0", "assignments": [
        {"dataLocation": "raw", "path": "sub-m1/", "entityType": "session", "key": {"subject_id": "m1", "session_id": "x"}}]})
    assert {r["identity"]["session_id"] for r in project.scan().records_of("session")} == {"m1-001", "m1-002", "m2-001"}


def test_integer_keys_are_typed(tmp_path):
    from nansen.dataset import Dataset

    config = {"schemaVersion": "0.1.0", "entityTypes": [{"name": "trial", "identifierRef": "trial"}],
              "metadataDefinitions": {"trial": {"name": "trial", "dataType": "integer", "ofEntity": "trial"}},
              "dataLocations": [{"identifier": "raw", "displayName": "Raw", "dataCategory": "raw", "sourceType": "filesystem",
                                 "filesystemSource": {"rootStoragePaths": [{"identifier": "here", "path": "data"}],
                                                      "entityLayout": [{"name": "trials", "entityType": "trial", "matchPattern": "^t\\d+$"}],
                                                      "metadataMapping": [{"metadataRef": "trial", "extraction": {
                                                          "method": "regex", "pattern": "^t(\\d+)$", "entityLayoutLevel": 0}}]}}]}
    (tmp_path / "dataset.dsm.json").write_text(json.dumps(config))
    (tmp_path / "data" / "t1").mkdir(parents=True)
    (tmp_path / "data" / "first try").mkdir()
    dataset = Dataset.load(tmp_path / "dataset.dsm.json")
    assert dataset.check_key("trial", {"trial": "7"}) == {"trial": 7}
    assert dataset.check_key("trial", {"trial": 7.0}) == {"trial": 7}
    for bad in ("7.5", 7.5, True, None, "seven"):
        with pytest.raises(NansenError):
            dataset.check_key("trial", {"trial": bad})
    scan = dataset.scan(assignments=[{"dataLocation": "raw", "path": "first try/", "entityType": "trial", "key": {"trial": 0}}])
    assert [(r["identity"]["trial"], r["locations"][0]["paths"]) for r in scan.records] == [(1, ["t1/"]), (0, ["first try/"])]
    assert scan.unmatched == []


def test_project_without_dataset(tmp_path):
    from nansen import Column

    project = Project.create(tmp_path, "Plain")
    assert project.dataset is None
    with pytest.raises(NansenError) as error:
        project.scan()
    assert error.value.code == "no-dataset"
    project.add_entity_type("trial", [Column("trial", "integer")])
    assert project.entities("trial") == []


def test_invalid_dataset(tmp_path):
    (tmp_path / "dataset.dsm.json").write_text(json.dumps({"schemaVersion": "0.1.0"}))
    project = Project.create(tmp_path, "Broken", dataset="dataset.dsm.json")
    with pytest.raises(NansenError) as error:
        project.dataset
    assert error.value.code == "dataset-invalid"


@pytest.mark.parametrize("recorded", ["/Volumes/LabDisk/data/raw", "E:\\data\\raw", "/media/someone/LabDisk/data/raw"])
def test_a_root_on_a_removable_drive_is_found_where_it_is_mounted_now(tmp_path, monkeypatch, recorded):
    import json as _json

    from nansen.dataset import Dataset, path_in_volume

    assert path_in_volume(recorded, "LabDisk") == "data/raw"
    mounted = tmp_path / "mounts" / "LabDisk" / "data" / "raw" / "sub-m1"
    mounted.mkdir(parents=True)
    config = {"schemaVersion": "0.1.0", "entityTypes": [{"name": "subject", "identifierRef": "subject_id"}],
              "metadataDefinitions": {"subject_id": {"name": "subject_id", "dataType": "string", "ofEntity": "subject"}},
              "dataLocations": [{"identifier": "raw", "displayName": "Raw", "dataCategory": "raw", "sourceType": "filesystem",
                                 "filesystemSource": {"rootStoragePaths": [{"identifier": "disk", "path": recorded, "volumeName": "LabDisk"}],
                                                      "entityLayout": [{"name": "subjects", "entityType": "subject", "matchPattern": "^sub-.+$"}],
                                                      "metadataMapping": [{"metadataRef": "subject_id", "extraction": {
                                                          "method": "regex", "pattern": "^sub-(.+)$", "entityLayoutLevel": 0}}]}}]}
    (tmp_path / "dataset.dsm.json").write_text(_json.dumps(config))
    dataset = Dataset.load(tmp_path / "dataset.dsm.json")
    assert dataset.roots()[0].available is False
    monkeypatch.setenv("NANSEN_VOLUME_ROOTS", str(tmp_path / "mounts"))
    root = dataset.roots()[0]
    assert root.available and root.path == tmp_path / "mounts" / "LabDisk" / "data" / "raw"
    assert len(dataset.scan().records) == 1
