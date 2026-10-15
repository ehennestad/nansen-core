"""Stacks read a chunk of frames at a time (nansen.stacks), recordings kept in several files, and the ophys
methods that read a recording in chunks and never whole."""

import shutil
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")
tifffile = pytest.importorskip("tifffile")

from nansen import stacks  # noqa: E402
from nansen.adapters import NpyAdapter  # noqa: E402
from nansen.api import Api  # noqa: E402
from nansen.errors import NansenError  # noqa: E402

CASE = Path(__file__).resolve().parents[2] / "conformance" / "api" / "ophys" / "project"
S2 = {"subject_id": "m1", "session_id": "s2"}


def test_a_stack_reads_only_the_frames_asked_for():
    data = np.arange(3 * 4 * 10).reshape(3, 4, 10)
    asked = []
    stack = stacks.Stack(data.shape, data.dtype, lambda a, b: asked.append((a, b)) or data[..., a:b])
    assert stack.shape == (3, 4, 10) and stack.ndim == 3 and stack.size == 120 and stack.frame_count == 10
    assert (stack[:, :, 2:5] == data[:, :, 2:5]).all() and asked == [(2, 5)]
    assert stack[1, 2, 7] == data[1, 2, 7] and stack[..., -1].shape == (3, 4)
    assert (stack[:, 1:3, ::4] == data[:, 1:3, ::4]).all()
    assert (np.asarray(stack.select(slice(None), 2)) == data[:, 2, :]).all()
    assert stack.frames(8, 50).shape == (3, 4, 2)   # cut to the stack
    stack.max_frames = 4
    with pytest.raises(NansenError):
        np.asarray(stack)   # reading everything is more than the limit allows
    assert stack.frames(0, 4).shape == (3, 4, 4)


def test_stacks_are_joined_along_the_frames():
    a, b = np.zeros((2, 2, 3)), np.ones((2, 2, 4))
    joined = stacks.join([a, b])
    assert joined.shape == (2, 2, 7)
    assert joined[:, :, 2:5][0, 0].tolist() == [0, 1, 1]
    with pytest.raises(NansenError):
        stacks.join([a, np.ones((2, 3, 1))])
    assert stacks.natural_order(["f_10.tif", "f_2.tif", "f_1.tif"]) == ["f_1.tif", "f_2.tif", "f_10.tif"]


def test_npy_files_are_memory_mapped_and_written_a_chunk_at_a_time(tmp_path):
    data = np.random.default_rng(0).integers(0, 1000, (5, 6, 30)).astype(np.uint16)
    with NpyAdapter().create(tmp_path / "out.npy", data.shape, data.dtype) as out:
        for start in range(0, 30, 7):
            out.write(start, data[:, :, start:start + 7])
    written = np.load(tmp_path / "out.npy")
    assert (written == data).all() and written.flags.f_contiguous   # frames kept together
    np.save(tmp_path / "more.npy", data + 1)
    stack = NpyAdapter().open([tmp_path / "more.npy", tmp_path / "out.npy"])
    # natural order: more.npy, then out.npy
    assert stack.shape == (5, 6, 60) and (stack[:, :, 28:32] == np.concatenate([data[:, :, 28:] + 1, data[:, :, :2]], 2)).all()


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


def test_a_recording_in_several_files_is_one_variable(api):
    project = api.project
    entity = project.entity("session", S2)
    parts = sorted((api.folder / "data" / "raw" / "sub-m1" / "ses-s2").glob("*.tif"))
    whole = np.concatenate([np.moveaxis(tifffile.imread(p), 0, 2) for p in stacks.natural_order(parts)], axis=2)
    assert whole.shape == (32, 32, 40)
    assert (project.load(entity, "TwoPhotonSeries_Original", cached=False) == whole).all()
    stack = project.open_stack(entity, "TwoPhotonSeries_Original")
    assert stack.shape == whole.shape and (stack[:, :, 13:17] == whole[:, :, 13:17]).all()   # across the two files


def test_files_of_one_recording_must_agree(tmp_path):
    from nansen.adapters import load_object
    tiff = load_object("ophys_adapters:TiffStack", CASE.parents[3] / "modules" / "ophys" / "python")()
    tifffile.imwrite(tmp_path / "a_1.tif", np.zeros((2, 8, 8), np.uint16))
    tifffile.imwrite(tmp_path / "a_2.tif", np.zeros((2, 6, 8), np.uint16))
    with pytest.raises(NansenError) as error:
        tiff.open([tmp_path / "a_1.tif", tmp_path / "a_2.tif"])   # refused when opened, not at the first read
    assert error.value.code == "invalid-data"


def test_a_writer_without_chunks_writes_when_it_closes(api):
    project = api.project
    entity = project.entity("session", S2)
    data = np.arange(4 * 5 * 6, dtype=np.float32).reshape(4, 5, 6)
    with project.stack_writer(entity, "TwoPhotonSeries_Corrected", data.shape, data.dtype) as out:   # npy: straight to the file
        out.write(0, data[:, :, :3])
        out.write(3, data[:, :, 3:])
    assert (project.load(entity, "TwoPhotonSeries_Corrected") == data).all()
    with project.stack_writer(entity, "", data.shape, data.dtype) as out:   # no variable: nothing written
        out.write(0, data)


def long_recording(api, frames=250):
    """Session s2's recording replaced by a longer one, in three files, with a few cells and known shifts."""
    rng = np.random.default_rng(7)
    scene = rng.normal(300, 40, (48, 48))
    stack = np.repeat(scene[:, :, None], frames, axis=2)
    yy, xx = np.mgrid[0:48, 0:48]
    for cy, cx in [(12, 12), (30, 20), (20, 36)]:
        stack[(yy - cy) ** 2 + (xx - cx) ** 2 <= 9] += 200 * (rng.random(frames) < 0.1)
    shifts = rng.integers(-2, 3, (frames, 2))
    for t, (dy, dx) in enumerate(shifts):
        stack[:, :, t] = np.roll(np.roll(stack[:, :, t], dy, 0), dx, 1)
    stack = np.clip(stack + rng.normal(0, 5, stack.shape), 0, 65535).astype(np.uint16)
    folder = api.folder / "data" / "raw" / "sub-m1" / "ses-s2"
    for old in folder.glob("*.tif"):
        old.unlink()
    for n, (a, b) in enumerate([(0, 90), (90, 170), (170, frames)], start=1):
        tifffile.imwrite(folder / f"rec_{n}.tif", np.moveaxis(stack[:, :, a:b], 2, 0), photometric="minisblack")
    call(api, "project.scan")
    return stack


def run(api, method, options):
    return call(api, "methods.run", methodId=method, entityType="session", keys=[S2], options=options)["results"][0]


def test_the_large_data_methods_read_a_recording_in_chunks(api):
    stack = long_recording(api)
    unlimited = run(api, "ophys.image_stats", {"stack": "TwoPhotonSeries_Original"})
    api.project.stack_frame_limit = 100   # a method that read the recording whole would fail now
    with pytest.raises(NansenError):
        np.asarray(api.project.open_stack(api.project.entity("session", S2), "TwoPhotonSeries_Original"))
    assert run(api, "ophys.image_stats", {"stack": "TwoPhotonSeries_Original"}) == unlimited
    assert unlimited["n_frames"] == 250 and unlimited["mean_intensity"] == round(float(stack.astype(float).mean()), 4)
    moved = run(api, "ophys.motion_correction", {"referenceFrames": 50})
    assert moved["frames"] == 250
    corrected = api.project.open_stack(api.project.entity("session", S2), "TwoPhotonSeries_Corrected")
    assert corrected.shape == (48, 48, 250) and corrected.dtype == np.uint16
    rois = {"imageSize": [48, 48], "rois": [{"id": 1, "pixels": [[y, x] for y in range(11, 14) for x in range(11, 14)]}]}
    api.project.save(api.project.entity("session", S2), "RoiArray", rois)
    signals = run(api, "ophys.extract_signals", {})
    assert signals["frames"] == 250 and signals["rois"] == 1
    assert run(api, "ophys.downsample", {"temporalFactor": 5, "spatialFactor": 2})["frames"] == 50
    frame = call(api, "data.frame", entityType="session", key=S2, variable="TwoPhotonSeries_Corrected", projection="mean")
    assert frame["frames"] == 250 and frame["frame"] is None
    image = call(api, "data.frame", entityType="session", key=S2, variable="FovAverageProjection")
    assert (image["height"], image["width"], image["frames"]) == (48, 48, 1)   # an image: its columns are not frames
    with pytest.raises(NansenError):   # this one needs every frame at once: refused under the limit
        run(api, "ophys.detect_rois", {})
    api.project.stack_frame_limit = None
    entity = api.project.entity("session", S2)
    whole = api.project.load(entity, "TwoPhotonSeries_Corrected", cached=False)
    assert np.asarray(api.project.open_stack(entity, "TwoPhotonSeries_Corrected")).tolist() == whole.tolist()
