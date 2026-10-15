"""A run that stopped goes on where it stopped (nansen.progress), and a method is not run again on entities it already
completed on (skipCompleted): dev's ImageStackProcessor's checkIfPartIsFinished and RedoIfCompleted."""

import json

import pytest

np = pytest.importorskip("numpy")
pytest.importorskip("tifffile")

from nansen import progress  # noqa: E402
from nansen.adapters import NpyAdapter  # noqa: E402
from nansen.methods import Cancelled, MethodContext  # noqa: E402
from nansen.tasks import TaskQueue  # noqa: E402

from test_stacks import S2, api, call, long_recording  # noqa: E402,F401  (api is a fixture)

OUTPUTS = ("TwoPhotonSeries_Corrected", "MotionCorrectionShifts")


class StopsAfter(MethodContext):
    """A context whose run is cancelled at its nth check: a run stopped part way (a crash, Cancel, the app closed)."""

    def __init__(self, checks, **kwargs):
        super().__init__(**kwargs)
        self.checks = checks

    def check_cancelled(self):
        self.checks -= 1
        if self.checks < 0:
            raise Cancelled()


def files(api, names=OUTPUTS):
    entity = api.project.entity("session", S2)
    return {name: api.project.write_path(entity, name).read_bytes() for name in names}


def remove(api, names=OUTPUTS):
    entity = api.project.entity("session", S2)
    for name in names:
        path = api.project.write_path(entity, name)
        path.unlink()
        assert not progress.progress_path(path).exists()   # complete: no progress document left


def sidecar(api, name="TwoPhotonSeries_Corrected"):
    path = progress.progress_path(api.project.write_path(api.project.entity("session", S2), name))
    return json.loads(path.read_text()) if path.is_file() else None


def run(api, method, options, checks=None):
    """Run the method on s2 in this process; with checks, stopped at that check. Returns the result and the log."""
    context = StopsAfter(checks, project=api.project) if checks is not None else MethodContext(project=api.project)
    entity = api.project.entity("session", S2)
    if checks is None:
        return api.project.run(method, [entity], options, context=context)[0], context.lines
    with pytest.raises(Cancelled):
        api.project.run(method, [entity], options, context=context)
    return None, context.lines


@pytest.mark.parametrize("options", [{"referenceFrames": 50, "iterations": 2},
                                     {"referenceFrames": 30, "iterations": 3, "subpixel": True, "patches": 2, "maxShift": 4}])
def test_motion_correction_stopped_part_way_goes_on_to_the_same_result(api, options):
    long_recording(api)   # 250 frames: 3 chunks per iteration
    whole, _ = run(api, "ophys.motion_correction", options)
    expected = files(api)
    remove(api)
    # checks: 1 before the method, then 1 per chunk. Stopped in the first iteration, after 2 of its 3 chunks
    run(api, "ophys.motion_correction", options, checks=3)
    state = sidecar(api)
    assert (state["pass"], state["passes"], state["framesDone"]) == (1, options["iterations"], 200)
    assert sorted(state["state"]) == ["reference", "total"] and state["method"]["id"] == "ophys.motion_correction"
    # going on, stopped again in the last iteration, after one chunk of it written
    _, lines = run(api, "ophys.motion_correction", options, checks=1 + 1 + 3 * (options["iterations"] - 2) + 1)
    assert any("going on from frame 200 of iteration 1" in line for line in lines)
    state = sidecar(api)
    assert (state["pass"], state["framesDone"]) == (options["iterations"], 100) and sorted(state["state"]) == ["reference", "shifts"]
    assert state["state"]["shifts"]["shape"][:2] == [100, 2]
    # and to the end: the aligned stack and the shifts are those of the run that never stopped, byte for byte
    result, lines = run(api, "ophys.motion_correction", options)
    assert any(f"going on from frame 100 of iteration {options['iterations']}" in line for line in lines)
    assert result == whole and files(api) == expected
    assert sidecar(api) is None
    # complete, a run starts from the first frame again
    _, lines = run(api, "ophys.motion_correction", options)
    assert not any("going on" in line for line in lines) and files(api) == expected


def test_a_run_with_other_options_starts_over(api):
    long_recording(api)
    run(api, "ophys.motion_correction", {"referenceFrames": 50}, checks=5)
    assert sidecar(api)["pass"] == 2
    other, lines = run(api, "ophys.motion_correction", {"referenceFrames": 40})
    assert not any("going on" in line for line in lines) and sidecar(api) is None
    expected = files(api)
    remove(api)
    assert run(api, "ophys.motion_correction", {"referenceFrames": 40})[0] == other and files(api) == expected


def test_an_output_cut_short_or_changed_is_written_again(api):
    long_recording(api)
    whole, _ = run(api, "ophys.motion_correction", {"iterations": 1})
    expected = files(api)
    remove(api)
    run(api, "ophys.motion_correction", {"iterations": 1}, checks=3)
    path = api.project.write_path(api.project.entity("session", S2), "TwoPhotonSeries_Corrected")
    header = path.stat().st_size - 48 * 48 * 2 * 250
    with open(path, "r+b") as f:
        f.truncate(header + 48 * 48 * 2 * 150)   # as MATLAB's writer leaves a file: frames in order, 150 of the 200 done
    _, lines = run(api, "ophys.motion_correction", {"iterations": 1})
    assert not any("going on" in line for line in lines)   # the file lacks frames: started over
    assert files(api) == expected
    remove(api)
    run(api, "ophys.motion_correction", {"iterations": 1}, checks=3)
    with open(path, "r+b") as f:
        f.truncate(header + 48 * 48 * 2 * 220)   # cut short after the frames done: filled out and gone on with
    result, lines = run(api, "ophys.motion_correction", {"iterations": 1})
    assert any("going on from frame 200" in line for line in lines) and result == whole and files(api) == expected


def test_a_run_goes_on_from_progress_as_matlab_writes_it(api):
    long_recording(api)
    options = {"referenceFrames": 50, "iterations": 2}
    whole, _ = run(api, "ophys.motion_correction", options)
    expected = files(api)
    remove(api)
    run(api, "ophys.motion_correction", options, checks=1 + 3 + 1)
    path = progress.progress_path(api.project.write_path(api.project.entity("session", S2), "TwoPhotonSeries_Corrected"))
    document = json.loads(path.read_text())
    assert document["state"]["shifts"]["shape"] == [100, 2, 1, 1]
    document["state"]["shifts"]["shape"] = [100, 2]   # MATLAB's size leaves out trailing ones
    path.write_text(json.dumps(document))
    result, lines = run(api, "ophys.motion_correction", options)
    assert any("going on from frame 100 of iteration 2" in line for line in lines)
    assert result == whole and files(api) == expected


def test_arrays_are_kept_exactly():
    values = np.random.default_rng(1).normal(size=(3, 4, 2))
    kept = progress.decode(json.loads(json.dumps(progress.encode(values))))
    assert kept.dtype == values.dtype and kept.tobytes() == values.tobytes()
    encoded = progress.encode(np.array([[1, 2, 3], [4, 5, 6]], dtype=np.int32))
    assert encoded["shape"] == [2, 3] and np.frombuffer(__import__("base64").b64decode(encoded["data"]), "<i4").tolist() == [1, 4, 2, 5, 3, 6]


def test_an_npy_file_begun_is_reopened(tmp_path):
    data = np.arange(4 * 5 * 9, dtype=np.uint16).reshape(4, 5, 9)
    path = tmp_path / "a.npy"
    with NpyAdapter().create(path, data.shape, data.dtype) as out:
        out.write(0, data[:, :, :4])
    writer = NpyAdapter().reopen(path, data.shape, data.dtype)
    assert writer.frames_on_disk == 9
    with writer as out:
        out.write(4, data[:, :, 4:])
    assert (np.load(path) == data).all()
    assert NpyAdapter().reopen(path, (4, 5, 8), data.dtype) is None and NpyAdapter().reopen(path, data.shape, np.int16) is None


@pytest.mark.parametrize("method, options, output, checks", [
    ("ophys.denoise", {"stack": "TwoPhotonSeries_Original", "temporalSigma": 2, "spatialSigma": 1}, "TwoPhotonSeries_Denoised", 2),
    ("ophys.crop", {"stack": "TwoPhotonSeries_Original", "firstRow": 3, "lastRow": 40, "firstFrame": 20, "lastFrame": 0}, "TwoPhotonSeries_Cropped", 2),
    ("ophys.deinterleave", {"channels": 2, "planes": 1}, "TwoPhotonSeries_Deinterleaved", 2)])
def test_other_stack_writers_go_on_where_they_stopped(api, method, options, output, checks):
    long_recording(api)
    whole, _ = run(api, method, options)
    expected = files(api, [output])
    remove(api, [output])
    run(api, method, options, checks=checks)
    assert sidecar(api, output)["framesDone"] > 0
    result, lines = run(api, method, options)
    assert result == whole and files(api, [output]) == expected and sidecar(api, output) is None


def test_skip_completed_leaves_out_entities_whose_outputs_are_there(api):
    long_recording(api)
    s4 = {"subject_id": "m1", "session_id": "s4"}
    options = {"referenceFrames": 10, "iterations": 1}
    first = call(api, "methods.run", methodId="ophys.motion_correction", entityType="session", keys=[S2], options=options)
    assert first["skipped"] == []
    both = call(api, "methods.run", methodId="ophys.motion_correction", entityType="session", keys=[s4, S2], options=options,
                skipCompleted=True)
    assert both["skipped"] == [S2] and len(both["results"]) == 1
    again = call(api, "methods.run", methodId="ophys.motion_correction", entityType="session", keys=[s4, S2], options=options,
                 skipCompleted=True)
    assert again == {"results": [], "skipped": [S2, s4]}   # in the order of the table
    # an output gone, or still being written, is not done
    entity = api.project.entity("session", S2)
    shifts = api.project.write_path(entity, "MotionCorrectionShifts")
    shifts.unlink()
    assert api.project.already_done("ophys.motion_correction", [entity]) == [False]
    call(api, "methods.run", methodId="ophys.motion_correction", entityType="session", keys=[S2], options=options)
    stack = api.project.write_path(entity, "TwoPhotonSeries_Corrected")
    progress.progress_path(stack).write_text("{}")
    assert api.project.already_done("ophys.motion_correction", [entity]) == [False]
    progress.progress_path(stack).unlink()
    assert api.project.already_done("ophys.motion_correction", [entity]) == [True]
    # a mark undone in the run journal (the pipeline viewer) takes it back
    api.handle({"id": 3, "method": "pipelines.markStep", "params": {"entityType": "session", "method": "ophys.motion_correction", "keys": [S2], "done": False}})
    assert api.project.already_done("ophys.motion_correction", [entity]) == [False]
    with pytest.raises(Exception):
        call(api, "methods.run", methodId="ophys.motion_correction", entityType="session", keys=[S2], skipCompleted="yes")


def test_a_task_stopped_part_way_is_retried_where_it_stopped(api, monkeypatch):
    long_recording(api)
    s4 = {"subject_id": "m1", "session_id": "s4"}
    options = {"referenceFrames": 50, "iterations": 2}
    run(api, "ophys.motion_correction", options)
    expected = files(api)
    remove(api)
    queue = TaskQueue(api.project)
    import nansen.tasks
    # s4 (12 frames: 3 checks) completes, then s2 stops in its second iteration
    monkeypatch.setattr(nansen.tasks, "MethodContext", lambda **kwargs: StopsAfter(3 + 1 + 3 + 1, **kwargs))
    task = queue.submit("ophys.motion_correction", [api.project.entity("session", s4), api.project.entity("session", S2)],
                        options, skip_completed=True)
    assert task["skipCompleted"] is True
    stopped = queue.run_next()
    assert stopped["status"] == "cancelled" and stopped["skipped"] == []
    assert sidecar(api)["pass"] == 2
    monkeypatch.undo()
    again = queue.retry(stopped["id"])
    assert again["skipCompleted"] is True
    done = queue.run_next()
    assert done["status"] == "completed" and done["skipped"] == [s4]   # s4 had completed: left out
    assert "going on from frame 100 of iteration 2" in queue.log(done["id"])
    assert files(api) == expected and sidecar(api) is None
    redo = queue.retry(done["id"], skip_completed=False)
    assert "skipCompleted" not in redo
    assert queue.run_next()["status"] == "completed"
