import json

import pytest

from nansen import Migration, NansenError, check_document, read_document

PROJECT = {"schemaType": "nansen.project", "schemaVersion": "0.1.0", "name": "P", "entityTypes": []}


def test_valid_document_is_returned():
    assert check_document(dict(PROJECT))["name"] == "P"


def test_expected_type_is_enforced():
    with pytest.raises(NansenError) as error:
        check_document(dict(PROJECT), expected_type="nansen.table")
    assert error.value.code == "unknown-schema-type"


def test_migration_chain_runs_in_order_and_sets_the_version():
    calls = []

    def rename(doc):
        calls.append("0.0")
        doc["name"] = doc.pop("projectName")
        return doc

    old = {"schemaType": "nansen.project", "schemaVersion": "0.0.4", "projectName": "Old", "entityTypes": []}
    migrated = check_document(old, migrations=[Migration("nansen.project", "0.0", "0.1", rename)])
    assert calls == ["0.0"]
    assert migrated["name"] == "Old"
    assert migrated["schemaVersion"] == "0.1.0"
    assert "projectName" not in migrated


def test_migration_for_another_type_is_not_used():
    old = dict(PROJECT, schemaVersion="0.0.1")
    with pytest.raises(NansenError) as error:
        check_document(old, migrations=[Migration("nansen.table", "0.0", "0.1", lambda d: d)])
    assert error.value.code == "unsupported-version"


def test_migration_must_move_forward():
    old = dict(PROJECT, schemaVersion="0.0.1")
    with pytest.raises(NansenError) as error:
        check_document(old, migrations=[Migration("nansen.project", "0.0", "0.0", lambda d: d)])
    assert error.value.code == "unsupported-version"


def test_migrated_document_is_still_validated():
    old = dict(PROJECT, schemaVersion="0.0.1")
    with pytest.raises(NansenError) as error:
        check_document(old, migrations=[Migration("nansen.project", "0.0", "0.1", lambda d: dict(d, extra=1))])
    assert error.value.code == "schema-validation"


def test_read_document_reports_missing_file(tmp_path):
    with pytest.raises(NansenError) as error:
        read_document(tmp_path / "nope.json")
    assert error.value.code == "file-not-found"


def test_read_document_reads_utf8(tmp_path):
    path = tmp_path / "p.json"
    path.write_text(json.dumps(dict(PROJECT, title="Ørsted")), encoding="utf-8")
    assert read_document(path)["title"] == "Ørsted"
