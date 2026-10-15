"""Demo projects, for trying the app and for UI tests.

The sessions demo (create_demo) is described in the core module's demo/ folder (demo.json and dataset.dsm.json),
which MATLAB's nansen.demo.create reads too. The two-photon quickstart (create_two_photon_demo) is described in the
ophys module's tutorial/ folder (tutorial.json and dataset.dsm.json), which MATLAB's nansen.demo.createTwoPhoton reads.
"""

from __future__ import annotations

import json
import math
import random
import shutil
from pathlib import Path

from .documents import PathLike
from .errors import NansenError
from .modules import built_in_modules_dir
from .project import Project


def demo_dir() -> Path:
    folder = built_in_modules_dir()
    if folder is None:
        raise FileNotFoundError("the built-in modules (with core/demo) were not found")
    return folder / "core" / "demo"


def tutorial_dir() -> Path:
    folder = built_in_modules_dir()
    if folder is None:
        raise FileNotFoundError("the built-in modules (with ophys/tutorial) were not found")
    return folder / "ophys" / "tutorial"


DEMO_KINDS = ("sessions", "two-photon")


def create_demo_kind(folder: PathLike, kind: str = "sessions") -> Project:
    """The demo of a kind: sessions (create_demo) or two-photon (create_two_photon_demo)."""
    if kind == "sessions":
        return create_demo(folder)
    if kind == "two-photon":
        return create_two_photon_demo(folder)
    raise NansenError("invalid-params", f"kind is one of {', '.join(DEMO_KINDS)}, not {kind!r}")


def _check_empty(folder: PathLike) -> Path:
    folder = Path(folder)
    if folder.exists() and any(folder.iterdir()):
        raise NansenError("folder-not-empty", f"{folder} is not empty")
    return folder


def create_demo(folder: PathLike, seed: int = 7) -> Project:
    """Write a demo dataset and project into an empty folder, scan it and fill the tables."""
    folder = _check_empty(folder)
    plan = json.loads((demo_dir() / "demo.json").read_text(encoding="utf-8"))
    rng = random.Random(seed)
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(demo_dir() / "dataset.dsm.json", folder / "dataset.dsm.json")
    for subject, sessions in plan["subjects"].items():
        for number, session in enumerate(sessions):
            date = session[:8]
            day = f"{date[:4]}_{date[4:6]}_{date[6:]}"
            hour = 9 + number * 2
            raw = folder / "data" / "raw" / day / f"{day}_{hour:02d}_{rng.randint(0, 59):02d}_00_{subject}-{session}"
            raw.mkdir(parents=True, exist_ok=True)
            (raw / "rec.raw").write_bytes(bytes(rng.randint(2000, 20000)))
            if rng.random() < plan["configChance"]:
                (raw / "rec.ini").write_text("[scan]\nzoom=2\n")
            if number < len(sessions) - 1:  # the newest session of each subject is not processed yet
                processed = folder / "data" / "processed" / f"subject-{subject}" / f"session-{subject}-{session}"
                processed.mkdir(parents=True, exist_ok=True)
                (processed / f"{subject}-{session}_motion_corrected.json").write_text(
                    json.dumps({"shifts": [rng.random() for _ in range(5)]}))
    info = plan["project"]
    project = Project.create(folder, info["name"], info["title"], dataset="dataset.dsm.json",
                             description=info["description"])
    project.add_module("core")
    for entity_type in plan["entityTypes"]:
        project.add_entity_type(entity_type["name"], fragments=entity_type["fragments"], title=entity_type["title"])
    for document in plan["dataVariables"]:
        project.add_data_variable(document)
    project.scan()
    for entity_type in plan["entityTypes"]:
        project.sync(entity_type["name"])
    sessions = project.table("session")
    for row in sessions.rows:
        key = {"subject_id": row["subject_id"], "session_id": row["session_id"]}
        sessions.update(key, description=rng.choice(plan["notes"]) or None, ignore=rng.random() < plan["ignoreChance"])
    sessions.write()
    project.update_fragment("session", "core.file_stats")
    for preset in plan["presets"]:
        project.save_preset(preset["methodId"], preset["name"], preset["values"], preset["description"])
    return Project.open(folder)


def create_two_photon_demo(folder: PathLike) -> Project:
    """Write the two-photon quickstart into an empty folder: a SciScan recording of synthetic cells per session, and a
    project over them (core and ophys modules) with its tables filled and the ophys variables set up."""
    folder = _check_empty(folder)
    try:
        import numpy  # noqa: F401
    except ImportError:
        raise NansenError("dependency-missing", "the two-photon quickstart needs numpy: pip install numpy") from None
    plan = json.loads((tutorial_dir() / "tutorial.json").read_text(encoding="utf-8"))
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(tutorial_dir() / "dataset.dsm.json", folder / "dataset.dsm.json")
    seeds = plan["seeds"]
    for subject_number, (subject, sessions) in enumerate(plan["subjects"].items(), start=1):
        fov_seed = seeds["subject"] * subject_number
        for session_number, session in enumerate(sessions, start=1):
            raw = folder / "data" / "raw" / f"sub-{subject}" / f"ses-{session}"
            raw.mkdir(parents=True, exist_ok=True)
            data = synthetic_recording(plan, fov_seed, fov_seed + seeds["session"] * session_number)
            data.transpose(2, 0, 1).astype(">u2").tofile(raw / "rec.raw")  # frame after frame, line after line
            (raw / "rec.ini").write_bytes(sciscan_ini(plan["recording"]).encode("latin-1"))
    info = plan["project"]
    project = Project.create(folder, info["name"], info["title"], dataset="dataset.dsm.json",
                             description=info["description"])
    project.add_module("core")
    project.add_module("ophys")
    for entity_type in plan["entityTypes"]:
        project.add_entity_type(entity_type["name"], fragments=entity_type["fragments"], title=entity_type["title"])
    project.scan()
    for entity_type in plan["entityTypes"]:
        project.sync(entity_type["name"])
    project.run_tool("ophys.setup_variables", plan["setup"])
    for method in plan["methods"]:   # fills the frame rate and pixel size columns from the .ini files
        project.run(method["methodId"], project.entities(method["entityType"]))
    for preset in plan["presets"]:
        project.save_preset(preset["methodId"], preset["name"], preset["values"], preset["description"])
    return Project.open(folder)


def sciscan_ini(recording: dict) -> str:
    """The .ini file SciScan writes beside its .raw file, with the frame rate and the FOV (in m)."""
    lines = ["[_]", f"x.pixels = {recording['width']}", f"y.pixels = {recording['height']}", "no.of.channels = 1",
             f"no.of.frames.acquired = {recording['frames']}", "file.format = 0", 'save.ch.1 = "TRUE"',
             f'frames.p.sec = "{recording["framesPerSecond"]}"', f"x.fov = {recording['fov'][0]}",
             f"y.fov = {recording['fov'][1]}"]
    return "\n".join(lines) + "\n"


def lowbias32(x):
    """The lowbias32 hash of 32-bit integers, elementwise (uint32 arrays wrap)."""
    import numpy as np

    x = np.array(x, dtype=np.uint32, ndmin=1)
    with np.errstate(over="ignore"):
        x ^= x >> np.uint32(16)
        x *= np.uint32(0x7FEB352D)
        x ^= x >> np.uint32(15)
        x *= np.uint32(0x846CA68B)
        x ^= x >> np.uint32(16)
    return x


def hash_uniform(seed: int, index):
    """Numbers in [0, 1) for a seed and integer indexes: the top 24 bits of lowbias32(lowbias32(seed) ^ index) over
    2^24, exact doubles in both languages."""
    import numpy as np

    hashed = lowbias32(lowbias32(seed) ^ np.asarray(index, dtype=np.uint32))
    return (hashed >> np.uint32(8)).astype(np.float64) / 16777216.0


def cell_centres(plan: dict, fov_seed: int) -> list:
    """The (row, column) centres of a field of view's cells in the frame: candidate places drawn until count of them
    are at least minDistance apart."""
    recording, cells = plan["recording"], plan["cells"]
    centres, candidate = [], 0
    while len(centres) < cells["count"] and candidate < 100 * cells["count"]:
        u = hash_uniform(fov_seed, [2 * candidate, 2 * candidate + 1])
        y = cells["margin"] + math.floor(u[0] * (recording["height"] - 2 * cells["margin"]))
        x = cells["margin"] + math.floor(u[1] * (recording["width"] - 2 * cells["margin"]))
        candidate += 1
        if all((y - cy) ** 2 + (x - cx) ** 2 >= cells["minDistance"] ** 2 for cy, cx in centres):
            centres.append((y, x))
    return centres


def synthetic_recording(plan: dict, fov_seed: int, seed: int):
    """A height x width x frames uint16 recording as tutorial.json describes it. MATLAB's nansen.demo.createTwoPhoton
    makes the same values with the same operations in the same order.

    A scene larger than the frame by maxShift on each side holds a background (bilinear value noise on a coarse grid,
    and a fine grain) and disk-shaped cells, max(0, 1 - d^2 / r^2), whose brightness is baseline + amplitude * c, with
    calcium c_t = decay * c_(t-1) + s_t from spikes s. Each frame is the scene cut out at a shift that walks by whole
    pixels, plus noise (four uniform numbers less 2, times noise), rounded as floor(x + 0.5) and clamped to uint16.
    """
    import numpy as np

    recording, cells, background = plan["recording"], plan["cells"], plan["background"]
    height, width, frames, pad = recording["height"], recording["width"], recording["frames"], recording["maxShift"]
    scene_height, scene_width = height + 2 * pad, width + 2 * pad
    rows = np.arange(scene_height)[:, None]
    columns = np.arange(scene_width)[None, :]

    # background: bilinear between hashed values on a grid, and a hashed grain per pixel
    spacing = background["grid"]
    stride = scene_width // spacing + 2
    gy, gx = rows // spacing, columns // spacing
    fy, fx = (rows % spacing) / spacing, (columns % spacing) / spacing
    corner = lambda dy, dx: hash_uniform(fov_seed + 2, (gy + dy) * stride + gx + dx)
    coarse = (corner(0, 0) * (1 - fy) + corner(1, 0) * fy) * (1 - fx) + (corner(0, 1) * (1 - fy) + corner(1, 1) * fy) * fx
    grain = hash_uniform(fov_seed + 3, rows * scene_width + columns)
    scene = background["level"] + background["coarse"] * coarse + background["fine"] * grain

    centres = [(y + pad, x + pad) for y, x in cell_centres(plan, fov_seed)]
    count = len(centres)
    amplitudes = cells["amplitude"] * (0.5 + hash_uniform(fov_seed + 1, np.arange(count)))
    spikes = (hash_uniform(seed, np.arange(count)[:, None] * frames + np.arange(frames)[None, :])
              < cells["spikeChance"]).astype(np.float64)
    calcium = np.zeros((count, frames))
    level = np.zeros(count)
    for t in range(frames):
        level = cells["decay"] * level + spikes[:, t]
        calcium[:, t] = level

    movie = np.empty((scene_height, scene_width, frames))
    movie[:] = scene[:, :, None]
    radius2 = cells["radius"] * cells["radius"]
    for k, (cy, cx) in enumerate(centres):   # one cell at a time, in order
        footprint = np.maximum(0.0, 1 - ((rows - cy) ** 2 + (columns - cx) ** 2) / radius2)
        brightness = cells["baseline"] + amplitudes[k] * calcium[k]
        movie = movie + footprint[:, :, None] * brightness[None, None, :]

    # motion: from one frame to the next, a pixel either way along each axis with moveChance, within maxShift
    u = hash_uniform(seed + 1, np.arange(2 * frames))
    chance = recording["moveChance"]
    step = lambda v: -1 if v < chance else (1 if v >= 1 - chance else 0)
    shifted = np.empty((height, width, frames))
    dy = dx = 0
    for t in range(frames):
        if t > 0:
            dy = min(max(dy + step(u[2 * t]), -pad), pad)
            dx = min(max(dx + step(u[2 * t + 1]), -pad), pad)
        shifted[:, :, t] = movie[pad - dy:pad - dy + height, pad - dx:pad - dx + width, t]

    index = ((np.arange(frames)[None, None, :] * height + np.arange(height)[:, None, None]) * width
             + np.arange(width)[None, :, None]) * 4
    noise = hash_uniform(seed + 2, index)
    for j in range(1, 4):
        noise = noise + hash_uniform(seed + 2, index + j)
    noise = (noise - 2) * recording["noise"]
    values = np.floor(shifted + noise + 0.5)
    return np.minimum(np.maximum(values, 0), 65535).astype(np.uint16)
