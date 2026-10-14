import pytest

from nansen import Column, NansenError, Project

NOTES = {"schemaType": "nansen.fragment", "schemaVersion": "0.1.0", "id": "notes", "version": "1.0.0",
         "columns": [{"name": "ignore", "dataType": "boolean", "default": False},
                     {"name": "description", "dataType": "string"}]}


def test_create_open_and_add_entity_type(tmp_path):
    project = Project.create(tmp_path / "p", "Pilot", title="Pilot study")
    project.add_fragment(NOTES)
    table = project.add_entity_type("session", [Column("session_id", "string")], ["notes"])
    table.add({"session_id": "s1", "description": "first"})
    table.write()

    reopened = Project.open(tmp_path / "p")
    assert reopened.name == "Pilot" and reopened.title == "Pilot study"
    assert reopened.entity_types == ["session"]
    assert reopened.table("session").rows == [{"session_id": "s1", "ignore": False, "description": "first"}]


def test_two_projects_are_independent(tmp_path):
    a = Project.create(tmp_path / "a", "A")
    b = Project.create(tmp_path / "b", "B")
    a.add_entity_type("subject", [Column("subject_id", "string")])
    assert Project.open(tmp_path / "a").entity_types == ["subject"]
    assert Project.open(tmp_path / "b").entity_types == []
    assert b.entity_types == []


def test_create_refuses_an_existing_project(tmp_path):
    Project.create(tmp_path, "A")
    with pytest.raises(NansenError) as error:
        Project.create(tmp_path, "B")
    assert error.value.code == "folder-not-empty"


def test_unknown_entity_type_and_fragment(tmp_path):
    project = Project.create(tmp_path, "A")
    with pytest.raises(NansenError) as error:
        project.table("session")
    assert error.value.code == "unknown-entity-type"
    with pytest.raises(NansenError) as error:
        project.add_entity_type("session", [Column("session_id", "string")], ["notes"])
    assert error.value.code == "unknown-fragment"
    assert project.entity_types == []


def test_invalid_names_are_rejected_before_anything_is_written(tmp_path):
    project = Project.create(tmp_path, "A")
    with pytest.raises(NansenError) as error:
        Project.create(tmp_path / "x", "not a name")
    assert error.value.code == "schema-validation"
    with pytest.raises(NansenError):
        project.add_fragment(dict(NOTES, id="Not-An-Id"))
    assert not list((tmp_path / "fragments").iterdir())


def test_rows_added_to_a_reopened_table_get_fragment_defaults(tmp_path):
    project = Project.create(tmp_path, "A")
    project.add_fragment(NOTES)
    project.add_entity_type("session", [Column("session_id", "string")], ["notes"])
    table = Project.open(tmp_path).table("session")
    table.add({"session_id": "s1"})
    assert table.get("s1") == {"session_id": "s1", "ignore": False, "description": None}


def test_failed_create_writes_nothing(tmp_path):
    with pytest.raises(NansenError):
        Project.create(tmp_path / "x", "not a name")
    assert not (tmp_path / "x").exists()
