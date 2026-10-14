import json

import pytest

from nansen import Project
from nansen.errors import NansenError
from nansen.notebook import tags_of
from nansen.tables import Column


def make_project(tmp_path):
    project = Project.create(tmp_path / "p", "P")
    project.add_entity_type("session", [Column("session_id", "string"), Column("run", "integer")])
    return project


def test_tags_are_ascii_words_in_order_each_once():
    assert tags_of("Bad #motion", "see #z-drift and #motion, #é #a_1") == ["motion", "z", "a_1"]


def test_notes_are_kept_newest_first_and_ids_are_not_reused(tmp_path):
    notebook = make_project(tmp_path).notebook("session")
    first = notebook.add({"session_id": "s1", "run": 1}, "first", author="ana")
    second = notebook.add({"run": 2, "session_id": "s1"}, "second", title="Run #2", note_type="todo", author="ana")
    assert (first["id"], second["id"]) == (1, 2)
    assert second["key"] == {"session_id": "s1", "run": 2} and second["tags"] == ["2"]
    assert [n["id"] for n in notebook.notes()] == [2, 1]
    assert [n["id"] for n in notebook.notes({"session_id": "s1", "run": 1})] == [1]
    notebook.remove(2)
    assert notebook.add({"session_id": "s1", "run": 1}, "third", author="ana")["id"] == 3
    document = json.loads(notebook.path.read_text())
    assert document["schemaType"] == "nansen.notebook" and document["nextId"] == 4
    assert [n["id"] for n in document["notes"]] == [1, 3]  # the file keeps writing order


def test_bad_keys_types_and_empty_notes_are_refused(tmp_path):
    notebook = make_project(tmp_path).notebook("session")
    for key in [{"session_id": "s1"}, {"session_id": "s1", "run": 1, "x": 1}, {"session_id": "s1", "run": True}, "s1"]:
        with pytest.raises(NansenError) as error:
            notebook.add(key, "text")
        assert error.value.code == "invalid-params"
    with pytest.raises(NansenError) as error:
        notebook.add({"session_id": "s1", "run": 1}, "text", note_type="urgent")
    assert error.value.code == "invalid-params"
    with pytest.raises(NansenError) as error:
        notebook.add({"session_id": "s1", "run": 1}, " ", title="")
    assert error.value.code == "invalid-params"
    with pytest.raises(NansenError) as error:
        notebook.remove(7)
    assert error.value.code == "unknown-note"


def test_unknown_entity_type(tmp_path):
    with pytest.raises(NansenError) as error:
        make_project(tmp_path).notebook("probe")
    assert error.value.code == "unknown-entity-type"
