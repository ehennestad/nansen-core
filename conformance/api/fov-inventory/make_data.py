"""Write this case's project and dev FOV inventories.

Run from the repository root: python conformance/api/fov-inventory/make_data.py

project/ has the ophys module, subjects with cranial windows and sessions with FOV positions and regions. data/ has
FOV inventories as dev's fovmanager saved them (Save Fov Inventory: fovDb, each map object as its toStruct), written
with scipy as plain structs, which both languages read: inventory.mat (two mice, one of them not in the project, with
windows, FOVs with sessions and images, injections, an annotation; images of 8-bit colour, of doubles and of logicals,
an FOV mirrored and one turned a quarter, a session listed by id only) and not_an_inventory.mat (no fovDb).
"""

import json
import shutil
import sys
from pathlib import Path

import numpy as np
import scipy.io

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "python" / "src"))

from nansen.project import Project  # noqa: E402
from nansen.tables import Column  # noqa: E402


def structs(items, fields):
    """A 1 x n MATLAB struct array of these fields (empty where an item has no value)."""
    array = np.zeros((1, len(items)), dtype=[(f, object) for f in fields])
    for i, item in enumerate(items):
        for f in fields:
            array[0, i][f] = item.get(f, np.zeros((0, 0)))
    return array


def square(cx, cy, hw, hh):
    """dev's FoV edge: upper left and counterclockwise"""
    return np.array([[cx - hw, cy + hh], [cx - hw, cy - hh], [cx + hw, cy - hh], [cx + hw, cy + hh]])


BASE = ["center", "shape", "edge", "image", "alpha", "orientation"]
ORIENTATION = lambda theta=0.0, mx=False, my=False: {"isMirroredX": np.uint8(mx), "isMirroredY": np.uint8(my), "theta": float(theta)}


def write_project(folder: Path) -> None:
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    shutil.copy(HERE.parent / "ophys" / "project" / "dataset.dsm.json", folder / "dataset.dsm.json")
    project = Project.create(folder, "FovInventory", dataset="dataset.dsm.json")
    project.add_module("ophys")
    subjects = project.add_entity_type("subject", key=[Column("subject_id", "string")], fragments=["ophys.cranial_window"])
    for subject in ("m1234", "m1235"):
        subjects.add({"subject_id": subject})
    subjects.write()
    sessions = project.add_entity_type("session", key=[Column("subject_id", "string"), Column("session_id", "string")],
                                       fragments=["ophys.fov_position", "ophys.fov_region"])
    for subject, session in (("m1234", "m1234-s1"), ("m1234", "m1234-s2"), ("m1235", "m1235-s1"), ("m1235", "m1235-s2")):
        sessions.add({"subject_id": subject, "session_id": session})
    sessions.write()


def write_inventories(folder: Path) -> None:
    folder.mkdir(exist_ok=True)
    colour = np.zeros((2, 3, 3), dtype=np.uint8)   # a 2 x 3 photo: red, green, blue across the top row
    colour[0, 0, 0], colour[0, 1, 1], colour[0, 2, 2], colour[1, :, :] = 255, 255, 255, 128
    grey = np.array([[0.0, 0.5], [1.0, np.nan]])   # an FOV image of doubles: scaled from 0 to 1
    fovs1 = structs([
        {"center": np.array([[2.3, -3.6]]), "shape": "square", "edge": square(2.3, -3.6, 0.25, 0.25),
         "orientation": ORIENTATION(mx=True), "currentSession": "m1234-s1",
         "listOfSessions": structs([{"sessionID": "m1234-s1", "depth": 150.0, "nRois": 12.0, "fovImage": grey}],
                                   ["sessionID", "depth", "nRois", "fovImage"])},
        {"center": np.array([[1.7, -2.0]]), "shape": "square", "edge": square(1.7, -2.0, 0.3, 0.2),
         "orientation": ORIENTATION(theta=-90.0), "image": np.array([[True, False, False], [False, True, True]]),
         "currentSession": "m1234-s2", "listOfSessions": np.array(["m1234-s2", "m1234-s3"], dtype=object)}],
        BASE + ["depth", "nRois", "currentSession", "listOfSessions"])
    windows1 = structs([{"center": np.array([[2.0, -2.5]]), "shape": "Round 2.5mm",
                         "edge": np.array([[3.4, -2.5], [2.0, -1.1], [0.6, -2.5], [2.0, -3.9]]),
                         "image": colour, "orientation": ORIENTATION(theta=90.0), "fovArray": fovs1}],
                       BASE + ["brainSurfaceAlphaMap", "fovArray"])
    windows2 = structs([{"center": np.array([[-2.0, -2.5]]), "shape": "Trapezoidal 3x5mm",
                         "edge": np.array([[-3.5, 0.0], [-4.5, -5.0], [0.5, -5.0], [-0.5, 0.0]]),
                         "orientation": ORIENTATION(), "fovArray": structs([], ["center"])}],
                       BASE + ["brainSurfaceAlphaMap", "fovArray"])
    injections = structs([{"center": np.array([[1.5, -1.5]]), "shape": "sphere", "name": "AAV-GCaMP8m", "color": "g",
                           "spread": 400.0, "volume": 50.0, "depth": "300"}],
                         BASE + ["name", "color", "spread", "volume", "depth"])
    annotations = structs([{"center": np.array([[2.0, -3.0]]), "shape": "circle", "name": "blood vessel", "color": "r",
                            "radius": 100.0}], BASE + ["name", "color", "radius"])
    db = structs([
        {"MouseId": "1234", "HeadbarLabel": "HB-7", "Windows": windows1, "Injections": injections, "Annotations": annotations},
        {"MouseId": "1235", "HeadbarLabel": "", "Windows": windows2, "Injections": structs([], ["center"]),
         "Annotations": structs([], ["center"])},
        {"MouseId": "4321", "HeadbarLabel": "", "Windows": structs([], ["center"]),
         "Injections": structs([{"center": np.array([[0.5, 0.5]]), "name": "CTB", "color": "b"}], ["center", "name", "color"]),
         "Annotations": structs([], ["center"])}],
        ["MouseId", "HeadbarLabel", "Windows", "Injections", "Annotations"])
    scipy.io.savemat(folder / "inventory.mat", {"fovDb": db})
    scipy.io.savemat(folder / "not_an_inventory.mat", {"settings": {"defaultFilePath": ""}})


if __name__ == "__main__":
    write_project(HERE / "project")
    write_inventories(HERE / "data")
    print(json.dumps(sorted(p.relative_to(HERE).as_posix() for p in HERE.rglob("*") if p.is_file())))
