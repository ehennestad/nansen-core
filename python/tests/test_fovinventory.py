"""dev's FOV inventories (fovmanager's Save Fov Inventory) read, planned onto the FOV map and imported."""

import base64
import json
import shutil
from pathlib import Path

import pytest

from nansen import fovinventory
from nansen.api import Api
from nansen.errors import NansenError
from nansen.legacy import plan_legacy

ROOT = Path(__file__).resolve().parents[2]
CASE = ROOT / "conformance" / "api" / "fov-inventory"
LEGACY = ROOT / "conformance" / "legacy" / "fov-inventory" / "export.json"


def pixels(image):
    return list(base64.b64decode(image["pixels"]))


def test_a_mat_file_of_plain_structs_is_read_as_fovmanager_showed_it():
    pytest.importorskip("scipy")
    inventory = fovinventory.read_inventory(CASE / "data" / "inventory.mat")
    assert inventory["schemaType"] == "nansen.legacyFovInventory" and inventory["source"].endswith("inventory.mat")
    first, second, third = inventory["mice"]
    assert (first["mouseId"], first["headbarLabel"], second["mouseId"], third["mouseId"]) == ("1234", "HB-7", "1235", "4321")
    window = first["windows"][0]
    assert (window["shape"], window["center"], window["rotation"]) == ("Round 2.5mm", [2.0, -2.5], 90.0)
    assert window["edge"] == [[3.4, -2.5], [2.0, -1.1], [0.6, -2.5], [2.0, -3.9]]
    # the photo upside down from how it was kept (MATLAB draws row 1 at the bottom of the map)
    assert (window["image"]["width"], window["image"]["height"]) == (3, 2)
    assert pixels(window["image"]) == [128] * 9 + [255, 0, 0, 0, 255, 0, 0, 0, 255]
    mirrored, turned = window["fovs"]
    assert mirrored["sessions"] == ["m1234-s1"] and turned["sessions"] == ["m1234-s2", "m1234-s3"]   # by id, and current
    # doubles scaled from 0 to 1 (NaN as 0), mirrored left to right, upside down
    assert [p[0] for p in zip(*[iter(pixels(mirrored["sessionImages"][0]["image"]))] * 3)] == [0, 255, 128, 0]
    # a logical image (0 and 255) turned a quarter clockwise (imrotate by theta -90, rot90 three times), upside down
    image = turned["image"]
    assert (image["width"], image["height"], turned["rotation"]) == (2, 3, -90.0)
    assert [p[0] for p in zip(*[iter(pixels(image))] * 3)] == [255, 0, 255, 0, 0, 255]
    assert first["injections"] == [{"center": [1.5, -1.5], "name": "AAV-GCaMP8m", "color": "g", "spread": 400.0,
                                    "volume": 50.0, "depth": "300"}]
    assert first["annotations"] == [{"center": [2.0, -3.0], "name": "blood vessel", "color": "r"}]


def test_fovmanagers_objects_and_v7_3_files_need_matlab(tmp_path, monkeypatch):
    scipy_io = pytest.importorskip("scipy.io")
    from scipy.io.matlab import MatlabOpaque
    import numpy as np
    opaque = MatlabOpaque(np.zeros(1, dtype=[("s0", "O"), ("s1", "O"), ("s2", "O"), ("arr", "O")]))
    with pytest.raises(NansenError) as raised:
        fovinventory.normalize([{"MouseId": "1", "Windows": [], "Annotations": opaque}], "inventory.mat")
    assert raised.value.code == "legacy-needs-matlab" and "exportFovInventory" in raised.value.message

    def v73(*args, **kwargs):
        raise NotImplementedError("Please use HDF reader for matlab v7.3 files")
    monkeypatch.setattr(scipy_io, "loadmat", v73)
    with pytest.raises(NansenError) as raised:
        fovinventory.read_inventory(CASE / "data" / "inventory.mat")
    assert raised.value.code == "legacy-needs-matlab" and "v7.3" in raised.value.message


def window(shape, edge, center=(0, 0), rotation=0, **more):
    return dict({"shape": shape, "center": list(center), "edge": edge, "rotation": rotation, "fovs": []}, **more)


def plan_of(*windows, mouse="7", subjects=({"subject_id": "m7"},), sessions=()):
    inventory = {"mice": [{"mouseId": mouse, "headbarLabel": "", "windows": list(windows), "injections": [], "annotations": []}]}
    return fovinventory.plan(inventory, list(sessions), list(subjects))


def test_a_windows_outline_is_kept_when_it_is_not_its_shapes_own():
    circle = [[1.25, 0], [0, 1.25], [-1.25, 0], [0, -1.25]]
    assert plan_of(window("Round 2.5mm", circle))["marks"]["outlines"] == []
    assert plan_of(window("Round 2.5mm", [[2, 1], [1, 2.5], [0, 1], [1, -0.5]], (1, 1)))["marks"]["outlines"] == [
        {"id": 1, "subject": {"subject_id": "m7"}, "ellipse": [1, 1.5]}]
    trapezoid = [[x + 1, y - 1] for x, y in fovinventory.DEV_TRAPEZOID]   # dev's own, closed or not
    assert plan_of(window("Trapezoidal 3x5mm", trapezoid, (1, -1)))["marks"]["outlines"] == []
    assert plan_of(window("Custom Trapezoid", trapezoid + trapezoid[:1], (1, -1)))["marks"]["outlines"] == []
    planned = plan_of(window("Custom Trapezoid", [[0, 0], [2, 0], [1, 3]], (1, 1), rotation=45))
    assert planned["marks"]["outlines"][0]["polygon"] == [[-1, -1], [1, -1], [0, 2]]
    # dev's theta turns clockwise; the map's rotation is counterclockwise
    assert planned["windows"] == [{"key": {"subject_id": "m7"}, "values": {
        "window_ml": 1, "window_ap": 1, "window_shape": "trapezoid 3 x 5 mm", "window_rotation": 315}}]


def test_a_subject_is_found_by_the_mouses_id_or_with_m_before_it():
    assert plan_of(window("Round 2.5mm", []), subjects=[{"subject_id": "7"}, {"subject_id": "m7"}])["windows"][0]["key"] == {"subject_id": "7"}
    planned = plan_of(window("Round 2.5mm", []), subjects=[{"subject_id": "m8"}])
    assert planned["windows"] == [] and planned["warnings"] == [
        "mouse 7: no subject of that id; its window and headbar label are left out"]


def test_an_fovs_size_is_swapped_when_it_was_turned_a_quarter():
    fov = {"center": [1.25, -2.5], "edge": [[1, -2.4], [1, -2.6], [1.5, -2.6], [1.5, -2.4]], "rotation": 270,
           "sessions": ["s1", "s2"]}
    planned = plan_of(window("Round 2.5mm", [], fovs=[fov]), sessions=[{"subject_id": "m7", "session_id": "s1"}])
    assert planned["fovs"] == [{"key": {"subject_id": "m7", "session_id": "s1"},
                                "values": {"fov_ml": 1.25, "fov_ap": -2.5, "fov_width_um": 200, "fov_height_um": 500}}]
    assert planned["warnings"] == ["FOVs of sessions that are not here, left out: s2"]
    assert [fovinventory.quarter_turns(t) for t in (0, 44, 46, -90, 180, 270, 360, -45)] == [0, 0, 1, 3, 2, 3, 0, 0]


def test_injections_keep_what_dev_typed():
    inventory = {"mice": [{"mouseId": "7", "windows": [], "annotations": [], "injections": [
        {"center": [1.23456, 2], "name": "AAV", "depth": " 250.5 ", "color": "Yellow", "volume": 20},
        {"center": [0, 0], "depth": "100-200", "color": "k"},
        {"center": [0, 0], "name": "CTB", "depth": 300, "spread": 123.45678}]}]}
    injections = fovinventory.plan(inventory, [], [])["marks"]["injections"]
    assert injections == [{"id": 1, "ml": 1.2346, "ap": 2, "material": "AAV", "depth": 250.5, "volume": 20, "colour": "yellow"},
                          {"id": 2, "ml": 0, "ap": 0, "material": "(100-200 µm)"},
                          {"id": 3, "ml": 0, "ap": 0, "material": "CTB", "depth": 300, "spread": 123.4568}]


def test_images_are_written_as_24_bit_bmp_files():
    image = {"width": 1, "height": 2, "pixels": base64.b64encode(bytes([1, 2, 3, 4, 5, 6])).decode()}
    data = fovinventory.bmp(image)
    assert data[:2] == b"BM" and len(data) == 54 + 8 and int.from_bytes(data[2:6], "little") == 62
    assert data[54:] == bytes([6, 5, 4, 0, 3, 2, 1, 0])   # rows from the bottom, blue first, padded to 4 bytes
    with pytest.raises(NansenError):
        fovinventory.bmp(dict(image, width=2))


def test_marks_of_the_inventorys_subjects_are_replaced_and_others_kept():
    stored = {"injections": [{"id": 4, "subject": {"subject_id": "m7"}, "ml": 0, "ap": 0},
                             {"id": 9, "subject": {"subject_id": "m8"}, "ml": 0, "ap": 0}],
              "notes": [], "photos": [{"id": 2, "session": {"session_id": "s1"}, "path": "a.png"}], "extra": True}
    planned = {"subjects": [{"subject_id": "m7"}], "sessions": [{"session_id": "s1"}], "marks": {
        "injections": [{"id": 1, "subject": {"subject_id": "m7"}, "ml": 1, "ap": 1}], "notes": [], "photos": [],
        "outlines": [{"id": 1, "subject": {"subject_id": "m7"}, "ellipse": [1, 1]}], "headbars": []}}
    merged = fovinventory.merge_marks(stored, planned)
    assert [(m["id"], m["subject"]["subject_id"]) for m in merged["injections"]] == [(9, "m8"), (10, "m7")]
    assert merged["photos"] == [] and merged["outlines"][0]["id"] == 1 and merged["extra"] is True


@pytest.fixture
def api(tmp_path):
    shutil.copytree(CASE / "project", tmp_path / "project")
    api = Api(start_queue=False)
    assert "result" in api.handle({"id": 1, "method": "project.open", "params": {"path": str(tmp_path / "project")}})
    return api


def call(api, method, **params):
    return api.handle({"id": 2, "method": method, "params": params})


def test_the_app_imports_an_inventory_onto_the_fov_map(api):
    pytest.importorskip("scipy")
    events = []
    api.emit = lambda kind, payload: events.append(kind)
    report = call(api, "legacy.importFovInventory", path=str(CASE / "data" / "inventory.mat"))["result"]
    assert (report["injections"], report["photos"], report["revision"]) == (2, 3, 1)
    assert {"entities", "moduleData"} <= set(events)
    marks = json.loads(call(api, "modules.data", module="ophys", name="fovmap")["result"]["text"])
    assert marks["headbars"] == [{"id": 1, "subject": {"subject_id": "m1234"}, "label": "HB-7"}]
    assert marks["photos"][0] == {"id": 1, "subject": {"subject_id": "m1234"}, "path": "fovmap/window-1234.bmp",
                                  "width": 2.8, "height": 2.8, "opacity": 0.6}
    assert (api.project.folder / "fovmap" / "fov-m1234-s2.bmp").read_bytes()[:2] == b"BM"
    assert api.project.table("session").get({"subject_id": "m1234", "session_id": "m1234-s1"})["brain_region"] == "V1"


def test_an_inventory_of_objects_is_read_by_matlab_when_there_is_one(api, monkeypatch, tmp_path):
    def objects(path):
        raise fovinventory.needs_matlab(path, "it holds fovmanager's objects")
    monkeypatch.setattr(fovinventory, "read_inventory", objects)
    monkeypatch.setattr(Api, "_matlab", lambda self: None)
    error = call(api, "legacy.importFovInventory", path=str(CASE / "data" / "inventory.mat"))["error"]
    assert error["code"] == "legacy-needs-matlab" and "nansen.legacy.exportFovInventory" in error["message"]
    exported = {"schemaType": "nansen.legacyFovInventory", "schemaVersion": "0.1.0", "mice": [
        {"mouseId": "1234", "headbarLabel": "HB-9", "windows": [], "injections": [], "annotations": []}]}
    monkeypatch.setattr(Api, "_matlab", lambda self: "matlab")
    monkeypatch.setattr(Api, "_export_fov_inventory", lambda self, path: exported)
    assert call(api, "legacy.importFovInventory", path="inventory.mat")["result"]["headbars"] == 1


def test_the_import_needs_a_file_the_ophys_module_and_fov_positions(api, tmp_path):
    assert call(api, "legacy.importFovInventory", path="")["error"]["code"] == "invalid-params"
    api.project.document["entityTypes"][1]["fragments"] = []
    assert call(api, "legacy.importFovInventory", path=str(LEGACY))["error"]["code"] == "invalid-params"
    shutil.copytree(ROOT / "conformance" / "api" / "views" / "project", tmp_path / "views")   # the core module only
    call(api, "project.open", path=str(tmp_path / "views"))
    assert call(api, "legacy.importFovInventory", path=str(LEGACY))["error"]["code"] == "unknown-module"


def test_a_legacy_export_brings_its_inventory_and_legacy_import_takes_one(tmp_path):
    pytest.importorskip("scipy")
    export = json.loads(LEGACY.read_text())
    plan = plan_legacy(export)
    assert "ophys" in plan["modules"] and plan["moduleData"][0]["name"] == "fovmap" and len(plan["images"]) == 3
    del export["fovInventory"]
    assert plan_legacy(export)["moduleData"] == [] and plan_legacy(export)["modules"] == ["core"]
    source = tmp_path / "export.json"
    source.write_text(json.dumps(export))
    api = Api(start_queue=False)
    result = call(api, "legacy.import", source=str(source), path=str(tmp_path / "project"),
                  fovInventory=str(CASE / "data" / "inventory.mat"))["result"]
    assert "FOV inventory: mouse 4321: no subject of that id; its window and headbar label are left out" not in result["warnings"]
    row = api.project.table("session").get({"subject_id": "m1234", "session_id": "m1234-s1"})
    assert (row["fov_ml"], row["fov_ap"]) == (2.3, -3.6)
    assert (tmp_path / "project" / "fovmap" / "window-1234.bmp").is_file()
