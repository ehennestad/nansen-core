"""NANSEN dev's FOV inventories (fovmanager's Load / Save Fov Inventory), brought onto the ophys module's FOV map.

dev's fovmanager saved its inventory as a .mat file with one variable, ``fovDb``: a struct array of mice
(``MouseId``, ``HeadbarLabel``), each with its cranial windows (``Windows``: ``center``, ``shape``, ``edge``,
``image``, ``orientation``, and the fields of view in it, ``fovArray``: ``center``, ``edge``, ``image``,
``orientation``, ``currentSession``, ``listOfSessions``), injections (``Injections``: ``center``, ``name``,
``color``, ``spread``, ``volume``, ``depth``) and annotations (``Annotations``: ``center``, ``name``, ``color``), each
as the map object's toStruct. Map positions are in mm from bregma, x mediolateral and y anteroposterior, as here.

``read_inventory`` reads one as a ``nansen.legacyFovInventory`` document: a .mat file of plain structs (with scipy;
``normalize``), or the JSON that MATLAB's ``nansen.legacy.exportFovInventory`` writes, which also reads files that hold
fovmanager's objects. ``plan`` maps the document onto the FOV map, the same way as MATLAB's
``nansen.legacy.planFovInventory``:

- a session's FOV is the FOV whose sessions name it (dev's ``listOfSessions``, ``currentSession``): ``fov_ml``,
  ``fov_ap`` (its centre), ``fov_width_um`` and ``fov_height_um`` (its outline's extent, the two swapped when the FOV
  was turned a quarter);
- a subject's window is the first window of the mouse of its id (``MouseId``, or ``m`` and it, as dev's session ids):
  ``window_ml``, ``window_ap``, ``window_shape`` (dev's shapes: ``Round 2.5mm`` is ``round 2.5 mm``, its trapezoids
  ``trapezoid 3 x 5 mm``) and ``window_rotation`` (dev's ``theta`` is clockwise, this counterclockwise); an outline
  other than the shape's own (a round window of another size, a custom trapezoid, a window fitted to its photo) is an
  ``outline`` of the module's data: an ellipse (``[rx, ry]``, mm) for a round window, else a polygon (``[[x, y],
  ...]``, mm from the window's centre, before its rotation);
- images (a window's photo of the brain surface, an FOV's or a session's image) are written as BMP files into the
  project's ``fovmap`` folder, as fovmanager showed them, and are ``photos`` of the module's data: a window's over its
  outline's extent (``width``, ``height`` and ``offset`` from its centre, mm), an FOV's (``session``) in its FOV;
- injections are ``injections`` (what, depth, volume, spread, colour), annotations ``notes`` (their name), and the
  headbar labels ``headbars``.

Numbers are rounded as floor(v * 10^n + 0.5) / 10^n: positions and sizes in mm to 4 decimals, in µm to 3.
"""

from __future__ import annotations

import base64
import json
import math
import re
import struct
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .documents import PathLike, check_document, read_json
from .errors import NansenError

SCHEMA_TYPE = "nansen.legacyFovInventory"
WINDOW_SHAPES = {"Round 2.5mm": "round 2.5 mm", "Trapezoidal 3x5mm": "trapezoid 3 x 5 mm",
                 "Custom Trapezoid": "trapezoid 3 x 5 mm"}
# dev's CranialWindow.setWindowCoordinates: its trapezoid, 3 mm wide in front and 5 mm behind, 5 mm long
DEV_TRAPEZOID = [[-1.5, 2.5], [-2.5, -2.5], [2.5, -2.5], [1.5, 2.5]]
COLOURS = {"r": "red", "g": "green", "b": "blue", "m": "magenta", "c": "cyan", "y": "yellow"}
WINDOW_PHOTO_OPACITY = 0.6   # dev's addImage showed a window's photo at 0.6
FOLDER = "fovmap"
MARK_KINDS = ("injections", "notes", "photos", "outlines", "headbars")


# -- reading ----------------------------------------------------------------------------------------------------------

def read_inventory(path: PathLike) -> dict:
    """A FOV inventory as a nansen.legacyFovInventory document: a .mat file of fovmanager's (plain structs), or the JSON
    of one (MATLAB's nansen.legacy.exportFovInventory, or a nansen.legacyExport with one)."""
    path = Path(path)
    if not path.is_file():
        raise NansenError("file-not-found", f"no file {path}")
    if path.suffix.lower() == ".json":
        document = read_json(path)
        if isinstance(document, dict) and document.get("schemaType") == "nansen.legacyExport":
            if "fovInventory" not in document:
                raise NansenError("invalid-data", f"{path.name} is a legacy export without a FOV inventory")
            document = document["fovInventory"]
        return check_document(document, SCHEMA_TYPE, source=str(path))
    if path.suffix.lower() != ".mat":
        raise NansenError("unsupported-file", f"{path.name}: a FOV inventory is a .mat file of dev's fovmanager, or its JSON export")
    try:
        import scipy.io
    except ImportError:
        raise NansenError("adapter-unavailable", "reading a .mat file needs scipy") from None
    try:
        # mat_dtype: the types MATLAB loads (logical, and doubles that MATLAB kept as smaller integers)
        data = scipy.io.loadmat(str(path), squeeze_me=True, simplify_cells=True, mat_dtype=True, variable_names=["fovDb"])
    except NotImplementedError:   # scipy's word for a v7.3 file
        raise needs_matlab(path, "it is a MATLAB v7.3 file") from None
    except (ValueError, TypeError, OSError) as error:
        raise NansenError("invalid-data", f"{path.name} could not be read as a .mat file: {error}") from None
    if "fovDb" not in data:
        raise NansenError("invalid-data", f"{path.name} has no fovDb: it is not a FOV inventory of dev's fovmanager")
    return normalize(data["fovDb"], str(path))


def needs_matlab(path: PathLike, why: str) -> NansenError:
    return NansenError("legacy-needs-matlab", f"{Path(path).name}: {why}, which only MATLAB reads: export it with "
                                              "nansen.legacy.exportFovInventory(path, File=...) and import the JSON file")


class _Opaque(Exception):
    """A MATLAB object (fovmanager saved some as objects), which scipy cannot read."""


def normalize(fov_db: Any, source: str = "") -> dict:
    """fovmanager's fovDb, as scipy reads it (squeezed, cells simplified), as a nansen.legacyFovInventory document.
    The same as MATLAB's nansen.legacy.exportFovInventory reads it."""
    import numpy

    mice: List[dict] = []
    skipped: List[str] = []
    try:
        for index, entry in enumerate(_items(fov_db), start=1):
            entry = _struct(entry)
            mouse_id = _text(entry.get("MouseId")) if entry is not None else ""
            if not mouse_id:
                skipped.append(f"mouse {index}: no MouseId; left out")
                continue
            mouse = {"mouseId": mouse_id, "headbarLabel": _text(entry.get("HeadbarLabel")),
                     "windows": [], "injections": [], "annotations": []}
            for number, window in enumerate(_items(entry.get("Windows")), start=1):
                window = _struct(window) or {}
                center = _point(window.get("center"))
                if center is None:
                    skipped.append(f"mouse {mouse_id}: window {number} has no center; left out")
                    continue
                orientation = _struct(window.get("orientation")) or {}
                mirror = (_flag(orientation.get("isMirroredX")), _flag(orientation.get("isMirroredY")))
                item = {"shape": _text(window.get("shape")), "center": center, "edge": _points(window.get("edge")),
                        "rotation": _number(orientation.get("theta")) or 0.0}
                image = _image(_first(window, "image", "brainSurfaceImage"), mirror, 0, numpy)
                if image is not None:
                    item["image"] = image
                item["fovs"] = []
                for count, fov in enumerate(_items(window.get("fovArray")), start=1):
                    fov = _struct(fov) or {}
                    fov_center = _point(fov.get("center"))
                    if fov_center is None:
                        skipped.append(f"mouse {mouse_id}: FOV {count} of window {number} has no center; left out")
                        continue
                    item["fovs"].append(_fov(fov, fov_center, numpy))
                mouse["windows"].append(item)
            for number, injection in enumerate(_items(entry.get("Injections")), start=1):
                injection = _struct(injection) or {}
                center = _point(injection.get("center"))
                if center is None:
                    skipped.append(f"mouse {mouse_id}: injection {number} has no center; left out")
                    continue
                spot: Dict[str, Any] = {"center": center}
                for name in ("name", "color"):
                    if _text(injection.get(name)):
                        spot[name] = _text(injection.get(name))
                for name in ("spread", "volume"):
                    if _number(injection.get(name)) is not None:
                        spot[name] = _number(injection.get(name))
                depth = injection.get("depth")
                if isinstance(depth, str):
                    if depth:
                        spot["depth"] = depth
                elif _number(depth) is not None:
                    spot["depth"] = _number(depth)
                mouse["injections"].append(spot)
            for number, annotation in enumerate(_items(entry.get("Annotations")), start=1):
                annotation = _struct(annotation) or {}
                center = _point(annotation.get("center"))
                if center is None:
                    skipped.append(f"mouse {mouse_id}: annotation {number} has no center; left out")
                    continue
                note: Dict[str, Any] = {"center": center}
                for name in ("name", "color"):
                    if _text(annotation.get(name)):
                        note[name] = _text(annotation.get(name))
                mouse["annotations"].append(note)
            mice.append(mouse)
    except _Opaque:
        raise needs_matlab(source or "the file", "it holds fovmanager's objects") from None
    document = {"schemaType": SCHEMA_TYPE, "schemaVersion": "0.1.0", "source": source, "mice": mice}
    if skipped:
        document["skipped"] = skipped
    return check_document(document, SCHEMA_TYPE)


def _fov(fov: dict, center: List[float], numpy) -> dict:
    """An FOV of a window: its place, outline, turn, sessions and images (dev's FoV)."""
    orientation = _struct(fov.get("orientation")) or {}
    mirror = (_flag(orientation.get("isMirroredX")), _flag(orientation.get("isMirroredY")))
    rotation = _number(orientation.get("theta")) or 0.0
    turns = quarter_turns(rotation)
    sessions: List[str] = []
    images: List[dict] = []
    for entry in _items(fov.get("listOfSessions")):   # a struct of each session (sessionID, fovImage), or its id
        if isinstance(entry, str):
            session, image = entry, None
        else:
            entry = _struct(entry) or {}
            session, image = _text(entry.get("sessionID")), entry.get("fovImage")
        if not session or session in sessions:
            continue
        sessions.append(session)
        shown = _image(image, mirror, turns, numpy)
        if shown is not None:
            images.append({"session": session, "image": shown})
    current = _text(fov.get("currentSession"))
    if current and current not in sessions:
        sessions.append(current)
    item: Dict[str, Any] = {"center": center, "edge": _points(fov.get("edge")), "rotation": rotation, "sessions": sessions}
    image = _image(_first(fov, "image", "fovImage"), mirror, turns, numpy)
    if image is not None:
        item["image"] = image
    if images:
        item["sessionImages"] = images
    return item


def quarter_turns(rotation: float) -> int:
    """dev's orientation.theta (degrees) as quarter turns, 0 to 3: floor(theta / 90 + 0.5) mod 4."""
    return int(math.floor(rotation / 90 + 0.5)) % 4


def _image(value: Any, mirror: Tuple[bool, bool], turns: int, numpy) -> Optional[dict]:
    """An image as fovmanager showed it on the map: mirrored as orientation says, turned (imrotate, counterclockwise) a
    number of quarter turns, upside down (MATLAB draws row 1 at the bottom of the map's axes); as 8-bit RGB. An 8-bit
    image keeps its values, a logical one is 0 and 255, others are scaled from their smallest to their largest finite
    value as floor((v - low) / (high - low) * 255 + 0.5). None when there is none."""
    if value is None or isinstance(value, (str, dict, list)):
        return None
    array = numpy.asarray(value)
    if array.ndim == 1:   # a 1 x n image, which scipy squeezes
        array = array.reshape(1, -1)
    if array.size == 0 or array.ndim not in (2, 3) or array.dtype.kind not in "biuf":
        return None
    if array.ndim == 3:
        if array.shape[2] == 1:
            array = array[:, :, 0]
        elif array.shape[2] >= 3:
            array = array[:, :, :3]
        else:
            return None
    if array.dtype == numpy.uint8:
        pixels = array
    elif array.dtype == bool:
        pixels = array.astype(numpy.uint8) * 255
    else:
        values = array.astype(numpy.float64)
        finite = numpy.isfinite(values)
        pixels = numpy.zeros(values.shape, dtype=numpy.uint8)
        if finite.any():
            low, high = values[finite].min(), values[finite].max()
            if high > low:
                scaled = numpy.floor((values - low) / (high - low) * 255 + 0.5)
                scaled[~finite] = 0
                pixels = numpy.clip(scaled, 0, 255).astype(numpy.uint8)
    if pixels.ndim == 2:
        pixels = numpy.stack([pixels] * 3, axis=2)
    if mirror[0]:
        pixels = pixels[:, ::-1]
    if mirror[1]:
        pixels = pixels[::-1]
    pixels = numpy.rot90(pixels, turns)
    pixels = numpy.ascontiguousarray(pixels[::-1])
    return {"width": int(pixels.shape[1]), "height": int(pixels.shape[0]),
            "pixels": base64.b64encode(pixels.tobytes()).decode("ascii")}


def _items(value: Any) -> list:
    """A struct array, cell array or single struct as a list."""
    if value is None or isinstance(value, str):
        return [] if value is None else [value]
    if isinstance(value, dict):
        return [value]
    if isinstance(value, (list, tuple)):
        return list(value)
    if _is_opaque(value):
        raise _Opaque()
    try:
        import numpy
    except ImportError:   # pragma: no cover - scipy needs numpy
        return []
    if isinstance(value, numpy.ndarray):
        if value.size == 0:
            return []
        if value.dtype == object:
            return list(value.ravel())
    return [value]


def _struct(value: Any) -> Optional[dict]:
    if isinstance(value, dict):
        for item in value.values():
            if _is_opaque(item):
                raise _Opaque()
        return value
    if _is_opaque(value):
        raise _Opaque()
    return None


def _is_opaque(value: Any) -> bool:
    return type(value).__name__ in ("MatlabOpaque", "MatlabFunction", "MatlabObject")


def _first(entry: dict, *names: str) -> Any:
    for name in names:
        if name in entry and entry[name] is not None and not (hasattr(entry[name], "size") and entry[name].size == 0):
            return entry[name]
    return None


def _text(value: Any) -> str:
    """Text, or a whole number as text; '' otherwise."""
    if isinstance(value, str):
        return value
    number = _number(value)
    if number is not None and number == math.floor(number) and abs(number) < 2 ** 53:
        return str(int(number))
    return ""


def _number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or isinstance(value, str) or value is None:
        return None
    if hasattr(value, "size") and hasattr(value, "item"):
        if value.size != 1 or getattr(value, "dtype", None) is not None and value.dtype.kind not in "iuf":
            return None
        value = value.item()
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return float(value)
    return None


def _flag(value: Any) -> bool:
    if hasattr(value, "size") and hasattr(value, "item"):
        if value.size != 1:
            return False
        value = value.item()
    return isinstance(value, (bool, int, float)) and bool(value)


def _point(value: Any) -> Optional[List[float]]:
    points = _points(value)
    return points[0] if len(points) == 1 else None


def _points(value: Any) -> List[List[float]]:
    """[x, y] points of an n x 2 array (rows with a value that is not finite left out)."""
    try:
        import numpy
        array = numpy.asarray(value, dtype=numpy.float64)
    except (ImportError, TypeError, ValueError):
        return []
    if array.ndim == 1 and array.size == 2:
        array = array.reshape(1, 2)
    if array.ndim != 2 or array.shape[1] != 2:
        return []
    return [[float(x), float(y)] for x, y in array if math.isfinite(x) and math.isfinite(y)]


# -- planning ---------------------------------------------------------------------------------------------------------

def plan(inventory: dict, sessions: List[dict], subjects: List[dict]) -> dict:
    """The FOV map's data from an inventory, given the keys of the sessions (the entity type with FOV positions) and of
    the subjects (with cranial windows): {fovs: [{key, values}], windows: [{key, values}], marks (injections, notes,
    photos, outlines, headbars), images: [{path, image}], subjects (the keys of the mice found), sessions (the keys of
    the FOVs placed), warnings}."""
    fovs: List[dict] = []
    windows: List[dict] = []
    marks: Dict[str, List[dict]] = {kind: [] for kind in MARK_KINDS}
    images: List[dict] = []
    warnings: List[str] = list(inventory.get("skipped", []))
    placed: Dict[str, dict] = {}   # key text -> key
    found: List[dict] = []
    windowed: List[str] = []
    missing: List[str] = []
    twice: List[str] = []
    empty = 0

    def add(kind: str, mark: dict) -> None:
        marks[kind].append(dict(id=len(marks[kind]) + 1, **mark))

    for mouse in inventory["mice"]:
        mouse_id = mouse["mouseId"]
        subject = _subject(subjects, mouse_id)
        owner = {"subject": subject} if subject is not None else {}
        if subject is None:
            if mouse["windows"] or mouse.get("headbarLabel"):
                warnings.append(f"mouse {mouse_id}: no subject of that id; its window and headbar label are left out")
        elif _key_text(subject) not in [_key_text(k) for k in found]:
            found.append(subject)
        if subject is not None and mouse.get("headbarLabel"):
            add("headbars", dict(owner, label=mouse["headbarLabel"]))
        extra = 0
        for window in mouse["windows"]:
            if subject is not None and _key_text(subject) not in windowed:
                windowed.append(_key_text(subject))
                windows.append({"key": subject, "values": _window_values(window)})
                outline = _outline(window)
                if outline is not None:
                    add("outlines", dict(owner, **outline))
                photo = _window_photo(window, mouse_id)
                if photo is not None:
                    images.append({"path": photo["path"], "image": window["image"]})
                    add("photos", dict(owner, **photo))
            elif subject is not None:
                extra += 1
            for fov in window["fovs"]:
                if not fov["sessions"]:
                    empty += 1
                    continue
                width, height = _fov_size(fov)
                pictures = {item["session"]: item["image"] for item in fov.get("sessionImages", [])}
                for session_id in fov["sessions"]:
                    key = _session(sessions, session_id)
                    if key is None:
                        missing.append(session_id)
                        continue
                    if _key_text(key) in placed:
                        twice.append(session_id)
                        continue
                    placed[_key_text(key)] = key
                    values: Dict[str, Any] = {"fov_ml": _round(fov["center"][0], 4), "fov_ap": _round(fov["center"][1], 4)}
                    if width is not None:
                        values["fov_width_um"] = _round(width * 1000, 3)
                        values["fov_height_um"] = _round(height * 1000, 3)
                    fovs.append({"key": key, "values": values})
                    picture = pictures.get(session_id, fov.get("image"))
                    if picture is not None and width is not None and width > 0 and height > 0:
                        path = f"{FOLDER}/fov-{file_name(session_id)}.bmp"
                        images.append({"path": path, "image": picture})
                        add("photos", dict(owner, session=key, path=path, width=_round(width, 4),
                                           height=_round(height, 4), opacity=1))
        if extra:
            warnings.append(f"mouse {mouse_id}: {extra} more window(s); only the first is placed (the FOVs in them are)")
        for spot in mouse["injections"]:
            add("injections", dict(owner, **_injection(spot)))
        for annotation in mouse["annotations"]:
            add("notes", dict(owner, ml=_round(annotation["center"][0], 4), ap=_round(annotation["center"][1], 4),
                              text=annotation.get("name") or "Annotation"))
    if missing:
        warnings.append(f"FOVs of sessions that are not here, left out: {', '.join(missing)}")
    if twice:
        warnings.append(f"sessions in more than one FOV, placed in the first: {', '.join(twice)}")
    if empty:
        warnings.append(f"{empty} FOV(s) with no session; left out")
    return {"fovs": fovs, "windows": windows, "marks": marks, "images": images, "subjects": found,
            "sessions": list(placed.values()), "warnings": warnings}


def _window_values(window: dict) -> dict:
    return {"window_ml": _round(window["center"][0], 4), "window_ap": _round(window["center"][1], 4),
            "window_shape": WINDOW_SHAPES.get(window["shape"]),
            "window_rotation": _round((-window["rotation"]) % 360, 4)}


def _outline(window: dict) -> Optional[dict]:
    """The window's outline when it is not its shape's own: an ellipse of a round window, else a polygon."""
    edge = window["edge"]
    if not edge:
        return None
    cx, cy = window["center"]
    if window["shape"] == "Round 2.5mm":
        xs, ys = [p[0] for p in edge], [p[1] for p in edge]
        rx, ry = _round((max(xs) - min(xs)) / 2, 4), _round((max(ys) - min(ys)) / 2, 4)
        if (rx == 1.25 and ry == 1.25) or not (rx > 0 and ry > 0):
            return None
        return {"ellipse": [rx, ry]}
    points = [[_round(x - cx, 4), _round(y - cy, 4)] for x, y in edge]
    if len(points) < 3:
        return None
    if window["shape"] in WINDOW_SHAPES and points in (DEV_TRAPEZOID, DEV_TRAPEZOID + DEV_TRAPEZOID[:1]):
        return None
    return {"polygon": points}


def _window_photo(window: dict, mouse_id: str) -> Optional[dict]:
    """A window's photo over its outline's extent, as fovmanager drew it."""
    if "image" not in window or not window["edge"]:
        return None
    xs, ys = [p[0] for p in window["edge"]], [p[1] for p in window["edge"]]
    width, height = _round(max(xs) - min(xs), 4), _round(max(ys) - min(ys), 4)
    if not (width > 0 and height > 0):
        return None
    photo: Dict[str, Any] = {"path": f"{FOLDER}/window-{file_name(mouse_id)}.bmp", "width": width, "height": height,
                             "opacity": WINDOW_PHOTO_OPACITY}
    offset = [_round((min(xs) + max(xs)) / 2 - window["center"][0], 4), _round((min(ys) + max(ys)) / 2 - window["center"][1], 4)]
    if offset != [0, 0]:
        photo["offset"] = offset
    return photo


def _fov_size(fov: dict) -> Tuple[Optional[float], Optional[float]]:
    """An FOV's width and height on the map (mm): its outline's extent, swapped when it was turned a quarter."""
    if not fov["edge"]:
        return None, None
    xs, ys = [p[0] for p in fov["edge"]], [p[1] for p in fov["edge"]]
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    if quarter_turns(fov["rotation"]) % 2:
        width, height = height, width
    return width, height


def _injection(spot: dict) -> dict:
    """An injection as the FOV map keeps one: dev's depth (text) is a number when it is one, else said in what was
    injected."""
    mark: Dict[str, Any] = {"ml": _round(spot["center"][0], 4), "ap": _round(spot["center"][1], 4)}
    material = spot.get("name", "")
    depth = spot.get("depth")
    number = None
    if isinstance(depth, str):
        text = depth.strip()
        if re.fullmatch(r"\d+(\.\d+)?", text):
            number = float(text)
        elif text:
            material = f"{material} ({text} µm)"
    elif depth is not None:
        number = depth
    material = material.strip()
    if material:
        mark["material"] = material
    if number is not None:
        mark["depth"] = _round(number, 4)
    for name in ("volume", "spread"):
        if spot.get(name) is not None:
            mark[name] = _round(spot[name], 4)
    colour = colour_of(spot.get("color", ""))
    if colour is not None:
        mark["colour"] = colour
    return mark


def colour_of(color: str) -> Optional[str]:
    """dev's colour (a letter, as its Set Color menus set, or the colour's name) as the FOV map's; None for another."""
    text = color.strip().lower()
    return COLOURS.get(text) or (text if text in COLOURS.values() else None)


def _subject(subjects: List[dict], mouse_id: str) -> Optional[dict]:
    """The subject of a mouse: of its id, or of m and its id (dev's session ids start with m and the mouse's id)."""
    for wanted in (mouse_id, "m" + mouse_id):
        for key in subjects:
            if any(isinstance(v, str) and v == wanted for v in key.values()):
                return key
    return None


def _session(sessions: List[dict], session_id: str) -> Optional[dict]:
    for key in sessions:
        if any(isinstance(v, str) and v == session_id for v in key.values()):
            return key
    return None


def _key_text(key: dict) -> str:
    return json.dumps(key, sort_keys=True)


def _round(value: float, digits: int) -> Any:
    """floor(v * 10^digits + 0.5) / 10^digits, an int when it is a whole number."""
    scale = 10 ** digits
    rounded = math.floor(value * scale + 0.5) / scale
    return int(rounded) if rounded == math.floor(rounded) else rounded


def file_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]", "_", text)


def bmp(image: dict) -> bytes:
    """An image ({width, height, pixels}) as a 24-bit BMP file: rows from the bottom, blue, green, red, each row padded
    to a multiple of 4 bytes; MATLAB's nansen.legacy.applyFovInventory writes the same bytes."""
    width, height = image["width"], image["height"]
    pixels = base64.b64decode(image["pixels"])
    stride = width * 3
    if len(pixels) != stride * height:
        raise NansenError("invalid-data", f"an image of {width} x {height} has {len(pixels)} bytes")
    pad = b"\0" * ((4 - stride % 4) % 4)
    rows = []
    for row in range(height - 1, -1, -1):
        line = bytearray(pixels[row * stride:(row + 1) * stride])
        line[0::3], line[2::3] = line[2::3], line[0::3]
        rows.append(bytes(line) + pad)
    data = b"".join(rows)
    return (struct.pack("<2sIHHI", b"BM", 54 + len(data), 0, 0, 54)
            + struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(data), 2835, 2835, 0, 0) + data)


# -- applying ---------------------------------------------------------------------------------------------------------

def merge_marks(stored: Any, planned: dict) -> dict:
    """The FOV map's data with an inventory's marks: those stored of the subjects and sessions it has are replaced by
    its own (so importing it again changes nothing), the others kept (marks that are not objects are left out); its
    marks get ids after the stored ones. As MATLAB's nansen.legacy.applyFovInventory merges them."""
    stored = stored if isinstance(stored, dict) else {}
    subjects = [_key_text(k) for k in planned["subjects"]]
    sessions = [_key_text(k) for k in planned["sessions"]]
    merged = dict(stored)
    for kind in MARK_KINDS:
        kept = [m for m in (stored.get(kind) or []) if isinstance(m, dict) and not (
            isinstance(m.get("subject"), dict) and _key_text(m["subject"]) in subjects
            or isinstance(m.get("session"), dict) and _key_text(m["session"]) in sessions)]
        start = max([m["id"] for m in kept if isinstance(m.get("id"), (int, float)) and not isinstance(m["id"], bool)], default=0)
        merged[kind] = kept + [dict(m, id=int(start) + i) for i, m in enumerate(planned["marks"][kind], start=1)]
    return merged


def import_inventory(project, inventory: dict) -> dict:
    """Put a FOV inventory onto the project's FOV map: the sessions' FOV positions and the subjects' windows (their
    columns), the images (in the fovmap folder) and the marks (the ophys module's data, fovmap, merged as merge_marks
    does). Returns {fovEntityType, windowEntityType, sessions and subjects (the keys of the FOVs and windows placed),
    injections, notes, photos, outlines, headbars (how many of each), images (their paths), revision (of the module
    data), warnings}. As MATLAB's nansen.legacy.applyFovInventory."""
    from .documents import write_json

    if not any(m.id == "ophys" for m in project.modules):
        raise NansenError("unknown-module", "the project does not use the ophys module, whose FOV map this is")
    types = project.document["entityTypes"]
    fov_type = next((t["name"] for t in types if "ophys.fov_position" in t.get("fragments", [])), None)
    window_type = next((t["name"] for t in types if "ophys.cranial_window" in t.get("fragments", [])), None)
    if fov_type is None:
        raise NansenError("invalid-params", "no entity type has FOV positions (ophys.fov_position): run the tool "
                                            "ophys.setup_variables first")
    fov_table = project.table(fov_type)
    window_table = project.table(window_type) if window_type else None
    keys = lambda table: [{k: row[k] for k in table.spec.key} for row in table.to_json_rows()]
    planned = plan(inventory, keys(fov_table), keys(window_table) if window_table is not None else [])
    for fov in planned["fovs"]:
        fov_table.update(fov["key"], **fov["values"])
    if planned["fovs"]:
        fov_table.write()
    for window in planned["windows"]:
        window_table.update(window["key"], **window["values"])
    if planned["windows"]:
        window_table.write()
    for item in planned["images"]:
        target = project.folder / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(bmp(item["image"]))
    path = project.folder / "module-data" / "ophys" / "fovmap.json"
    stored, revision = None, 0
    if path.is_file():
        from .documents import read_document
        document = read_document(path, "nansen.moduleData")
        stored, revision = json.loads(document["text"]), document["revision"]
    document = {"schemaType": "nansen.moduleData", "schemaVersion": "0.1.0", "module": "ophys", "name": "fovmap",
                "revision": revision + 1, "text": json.dumps(merge_marks(stored, planned), ensure_ascii=False)}
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(path, check_document(document, "nansen.moduleData"))
    return dict({"fovEntityType": fov_type, "windowEntityType": window_type,
                 "sessions": [f["key"] for f in planned["fovs"]], "subjects": [w["key"] for w in planned["windows"]]},
                **{kind: len(planned["marks"][kind]) for kind in MARK_KINDS},
                images=[i["path"] for i in planned["images"]], revision=revision + 1, warnings=planned["warnings"])
