"""NANSEN dev's metadata files (nansen.devyaml): the YAML reader, and a stack's metadata taken from them when its own
files say nothing. MATLAB's DevYamlTest checks the same; conformance/yaml and conformance/api/dev-metadata hold both."""

import math
import shutil
from pathlib import Path

import numpy as np
import pytest

from nansen import devyaml
from nansen.api import Api
from nansen.errors import NansenError

CASE = Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project"
S2 = {"subject_id": "m1", "session_id": "s2"}


def test_numbers_and_special_values():
    value = devyaml.parse("a: .nan\nb: -.Inf\nc: 1.0E-5\nd: 007\ne: '1'\nf: 1e3\n")
    assert math.isnan(value["a"]) and value["b"] == -math.inf and value["c"] == 1e-5
    assert value["d"] == 7.0 and value["e"] == "1" and value["f"] == 1000.0


def test_line_ends_byte_order_mark_and_escapes():
    value = devyaml.parse("\ufeffa: \"x\\U0001F600\\x41\"\r\nb: [1,\r\n  2]\r\n")
    assert value == {"a": "x\U0001F600A", "b": [1, 2]}


def test_keys_that_are_not_matlab_names_are_left_out():
    assert devyaml.parse("end: 1\nok_2: 2\n_x: 3\n" + "k" * 64 + ": 4\n") == {"ok_2": 2}


@pytest.mark.parametrize("text", ["a: *x\n", "a: !!float 1\n", "- a\n b\n- c: 1\n  d\n", "{a: 1\n", "a: \"\\q\"\n",
                                  "a: |x\n  y\n", "a:\n  - 1\n - 2\n"])
def test_what_is_not_read(text):
    with pytest.raises(NansenError) as error:
        devyaml.parse(text)
    assert error.value.code == "invalid-data"


def test_a_stack_metadata_file_gives_frame_rate_pixel_size_and_plane_step():
    document = devyaml.parse("TimeIncrement: 0.04\nTimeIncrementUnit: second\nPhysicalSizeX: 1.5\nPhysicalSizeY: 1.5\n"
                             "PhysicalSizeXUnit: µm\nPhysicalSizeYUnit: micron\nPhysicalSizeZ: 2.0\nPhysicalSizeZUnit: pixel\n")
    assert devyaml.stack_metadata(document) == {"frameRate": 25.0, "pixelSize": [1.5, 1.5]}
    # an adapter's (setMetadata): in its groups; dev's defaults (unit pixel, N/A) say nothing
    assert devyaml.stack_metadata({"Data": {"SampleRate": 30.9}, "Custom": {"PhysicalSizeX": 1, "PhysicalSizeXUnit": "um"},
                                   "TimeIncrement": 1, "TimeIncrementUnit": "N/A"}) == {"frameRate": 30.9}
    assert devyaml.stack_metadata({"TimeIncrement": 250, "TimeIncrementUnit": "microseconds", "SampleRate": 2,
                                   "PhysicalSizeX": 300, "PhysicalSizeY": 300, "PhysicalSizeXUnit": "nanometre",
                                   "PhysicalSizeYUnit": "NM", "PhysicalSizeZ": 0.0025, "PhysicalSizeZUnit": "mm"}) == \
        {"frameRate": 4000.0, "pixelSize": [0.3, 0.3], "zStep": 2.5}
    assert devyaml.stack_metadata({"TimeIncrement": 0, "TimeIncrementUnit": "second", "SampleRate": True}) == {}
    assert devyaml.stack_metadata(None) == {} and devyaml.stack_metadata([1]) == {}


def test_the_metadata_file_beside_a_data_file(tmp_path, monkeypatch):
    data = tmp_path / "rec.tif"
    assert devyaml.read_sidecar(data) is None
    (tmp_path / "rec.yaml.txt").write_text("SampleRate: 2\n")   # dev's SaveYamlAsTxt
    assert devyaml.read_sidecar(data) == {"SampleRate": 2}
    (tmp_path / "rec.yaml").write_text("SampleRate: 3\n")   # the .yaml is read first, as dev did
    assert devyaml.read_sidecar(data) == {"SampleRate": 3}
    (tmp_path / "rec.yaml").write_text("SampleRate: [3\n")   # not read: none
    assert devyaml.read_sidecar(data) is None
    (tmp_path / "rec.yaml").write_text("- 3\n")   # not a mapping: none
    assert devyaml.read_sidecar(data) is None
    (tmp_path / "rec.yaml").write_text("SampleRate: 3\n")
    monkeypatch.setattr(devyaml, "SIDECAR_LIMIT", 5)   # too large: none
    assert devyaml.read_sidecar(data) is None


@pytest.fixture
def api(tmp_path):
    folder = tmp_path / "project"
    shutil.copytree(CASE, folder)
    api = Api(start_queue=False)
    for method, params in [("project.open", {"path": str(folder)}), ("project.scan", {}), ("project.sync", {}),
                           ("tools.run", {"methodId": "ophys.setup_variables",
                                          "options": {"rawFilePattern": "tiff", "rawFileAdapter": "ophys.tiff_stack"}})]:
        assert "result" in api.handle({"id": 1, "method": method, "params": params}), method
    api.folder = folder
    yield api
    api.close()


def call(api, method, **params):
    response = api.handle({"id": 2, "method": method, "params": params})
    if "error" in response:
        raise NansenError(response["error"]["code"], response["error"]["message"])
    return response["result"]


def test_a_recording_takes_what_its_files_do_not_say_from_devs_metadata_file(api):
    folder = api.folder / "data" / "raw" / "sub-m1" / "ses-s2"
    frame = lambda: call(api, "data.frame", entityType="session", key=S2, variable="TwoPhotonSeries_Original")["metadata"]
    assert frame() == {}   # TIFFs that say nothing
    # beside the first file of the recording, in natural order (rec_part2.tif, then rec_part10.tif)
    (folder / "rec_part2.yaml").write_text("TimeIncrement: 0.0625\nTimeIncrementUnit: second\nPhysicalSizeX: 2.0\n"
                                           "PhysicalSizeY: 2.0\nPhysicalSizeXUnit: micrometer\nPhysicalSizeYUnit: micrometer\n")
    (folder / "rec_part10.yaml").write_text("TimeIncrement: 1.0\nTimeIncrementUnit: second\n")
    project = api.project
    assert project.open_stack(project.entity("session", S2), "TwoPhotonSeries_Original").metadata == \
        {"frameRate": 16.0, "pixelSize": [2.0, 2.0]}
    # the entity's columns over dev's file (the viewer's stack properties, as dev's Edit Stack Properties wrote that file)
    call(api, "entities.update", entityType="session", key=S2, values={"frame_rate": 10, "z_step_um": 3})
    assert frame() == {"frameRate": 10.0, "pixelSize": [2.0, 2.0], "zStep": 3.0}


def test_signals_take_their_frame_rate_from_devs_metadata_file(api):
    project = api.project
    entity = project.entity("session", S2)
    names = [v.name for v in project.data_variables()]
    name = next(n for n in ("RoiSignals_MeanF", "RoiSignals_Dff") if n in names)
    project.save(entity, name, np.zeros((12, 2)))
    traces = lambda: call(api, "data.traces", entityType="session", key=S2, variables=[name])["frameRate"]
    assert traces() is None
    path = project.existing_files(entity, name)[0]
    path.with_suffix(".yaml").write_text("File:\n  FileAdapter: nansen.dataio.fileadapter.timeseries.RoiSignalArray\n"
                                         "Data:\n  SampleRate: 30.9\n")
    assert traces() == 30.9
    call(api, "entities.update", entityType="session", key=S2, values={"frame_rate": 10})   # the column, edited, wins
    assert traces() == 10
