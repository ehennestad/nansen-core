import datetime as dt
import random
import re

import pytest

from nansen import Column, EntityTable, NansenError, TableSpec, format_number, parse_csv

SPEC_COLUMNS = [Column("subject_id", "string"), Column("session_id", "string"), Column("ignore", "boolean"),
                Column("depth", "number"), Column("started_at", "datetime")]


def make_table():
    return EntityTable(TableSpec("session", ["subject_id", "session_id"], list(SPEC_COLUMNS)))


def test_round_trip_through_files(tmp_path):
    table = make_table()
    table.add({"subject_id": "m1", "session_id": "s1", "ignore": False, "depth": 12.5,
               "started_at": dt.datetime(2025, 5, 10, 10, 0, 0, 250999)})
    table.add({"subject_id": "m1", "session_id": "s2", "ignore": True})
    table.write(tmp_path / "session.table.nansen.json")
    again = EntityTable.read(tmp_path / "session.table.nansen.json")
    assert again.rows == [
        {"subject_id": "m1", "session_id": "s1", "ignore": False, "depth": 12.5,
         "started_at": dt.datetime(2025, 5, 10, 10, 0, 0, 250000)},
        {"subject_id": "m1", "session_id": "s2", "ignore": True, "depth": None, "started_at": None},
    ]
    assert again.spec.revision == 0


def test_revision_increments_and_detects_conflicts(tmp_path):
    path = tmp_path / "session.table.nansen.json"
    make_table().write(path)
    first, second = EntityTable.read(path), EntityTable.read(path)
    first.add({"subject_id": "m1", "session_id": "s1", "ignore": False})
    first.write()
    assert first.spec.revision == 1
    second.add({"subject_id": "m2", "session_id": "s1", "ignore": False})
    with pytest.raises(NansenError) as error:
        second.write()
    assert error.value.code == "revision-conflict"
    assert len(EntityTable.read(path)) == 1


def test_write_leaves_no_temporary_files(tmp_path):
    make_table().write(tmp_path / "session.table.nansen.json")
    assert sorted(p.name for p in tmp_path.iterdir()) == ["session.csv", "session.table.nansen.json"]


def test_get_update_remove():
    table = make_table()
    table.add({"subject_id": "m1", "session_id": "s1", "ignore": False})
    table.add({"subject_id": "m1", "session_id": "s2", "ignore": False})
    table.update(("m1", "s2"), ignore=True, depth=3)
    assert table.get({"subject_id": "m1", "session_id": "s2"})["depth"] == 3.0
    table.remove(("m1", "s1"))
    assert [r["session_id"] for r in table.rows] == ["s2"]
    assert table.has(("m1", "s2")) and not table.has(("m1", "s1"))
    with pytest.raises(NansenError):
        table.update(("m1", "s2"), session_id="s3")


def test_rows_are_copies():
    table = make_table()
    table.add({"subject_id": "m1", "session_id": "s1", "ignore": False})
    table.rows[0]["ignore"] = True
    assert table.get(("m1", "s1"))["ignore"] is False


@pytest.mark.parametrize("row,code", [
    ({"subject_id": "m1", "ignore": False}, "missing-key"),
    ({"subject_id": "m1", "session_id": "s1"}, "missing-value"),
    ({"subject_id": "m1", "session_id": "s1", "ignore": "yes"}, "invalid-value"),
    ({"subject_id": "m1", "session_id": "s1", "ignore": False, "depth": float("inf")}, "invalid-value"),
    ({"subject_id": "m1", "session_id": "s1", "ignore": False,
      "started_at": dt.datetime(2025, 1, 1, tzinfo=dt.timezone.utc)}, "invalid-value"),
])
def test_add_checks_values(row, code):
    with pytest.raises(NansenError) as error:
        make_table().add(row)
    assert error.value.code == code


def test_add_rejects_duplicates_and_unknown_columns():
    table = make_table()
    table.add({"subject_id": "m1", "session_id": "s1", "ignore": False})
    with pytest.raises(NansenError) as error:
        table.add({"subject_id": "m1", "session_id": "s1", "ignore": True})
    assert error.value.code == "duplicate-key"
    with pytest.raises(KeyError):
        table.add({"subject_id": "m1", "session_id": "s9", "ignore": True, "colour": "red"})


def test_add_columns_fills_defaults():
    table = make_table()
    table.add({"subject_id": "m1", "session_id": "s1", "ignore": False})
    table.add_columns([Column("qc", "boolean", "ophys.qc"), Column("snr", "number", "ophys.qc")],
                      {"qc": True}, ("ophys.qc", "1.0.0"))
    assert table.get(("m1", "s1"))["qc"] is True
    assert table.spec.fragments == {"ophys.qc": "1.0.0"}
    with pytest.raises(NansenError) as error:
        table.add_columns([Column("qc", "string")])
    assert error.value.code == "invalid-table-spec"


def test_nan_is_written_as_missing():
    table = make_table()
    table.add({"subject_id": "m1", "session_id": "s1", "ignore": False, "depth": float("nan")})
    assert table.to_csv().splitlines()[1] == "m1,s1,false,,"


NUMBER = re.compile(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$")


def test_format_number_round_trips_and_matches_the_grammar():
    rng = random.Random(0)
    values = [rng.uniform(-1e6, 1e6) for _ in range(2000)]
    values += [10 ** rng.uniform(-30, 30) for _ in range(2000)]
    values += [float(rng.randint(-10**6, 10**6)) for _ in range(500)]
    for value in values:
        text = format_number(value)
        assert NUMBER.match(text), text
        assert float(text) == value


def test_format_number_rejects_non_finite():
    with pytest.raises(ValueError):
        format_number(float("inf"))


def test_parse_csv_reports_quoting():
    records = parse_csv('a,b\n"",\n')
    assert [(f.text, f.quoted) for f in records[1]] == [("", True), ("", False)]
