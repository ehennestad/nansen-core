"""The layout of an HDF5 file (NWB, MATLAB v7.3, .h5) for files.inspect: its groups, datasets and links."""
from __future__ import annotations

from pathlib import Path

from .errors import NansenError


def data_type(dtype) -> str:
    """The shared name of an HDF5 type: float32, int16, uint8, string, enum, compound, reference or other."""
    import h5py

    if h5py.check_string_dtype(dtype) is not None or dtype.kind == "S":
        return "string"
    if h5py.check_ref_dtype(dtype) is not None:
        return "reference"
    if dtype.kind == "b" or h5py.check_enum_dtype(dtype) is not None:
        return "enum"
    if dtype.kind in "fiu":
        return {"f": "float", "i": "int", "u": "uint"}[dtype.kind] + str(dtype.itemsize * 8)
    if dtype.kind == "V" and dtype.names:
        return "compound"
    return "other"


def _plain(value):
    """A scalar attribute or dataset value as JSON, or None when it is not a single string or number."""
    import numpy as np

    if isinstance(value, np.ndarray):
        if value.size != 1:
            return None
        value = value.reshape(-1)[0]
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    if isinstance(value, str):
        return value
    if isinstance(value, (bool, np.bool_)):
        return bool(value)
    if isinstance(value, (int, np.integer)):
        return int(value)
    if isinstance(value, (float, np.floating)):
        return float(value) if np.isfinite(value) else None
    return None


def _attributes(node) -> dict:
    out = {}
    for name in sorted(node.attrs.keys()):
        try:
            value = _plain(node.attrs[name])
        except (OSError, TypeError, ValueError):
            continue  # a type h5py cannot read, such as an object reference
        if value is not None:
            out[name] = value
    return out


def inspect(path: Path, limit: int = 2000) -> dict:
    """Each group, dataset and link of the file by path, the root first, then in path order."""
    try:
        import h5py
    except ImportError:
        raise NansenError("dependency-missing", "Reading HDF5 files needs h5py: pip install h5py") from None
    if not h5py.is_hdf5(str(path)):
        raise NansenError("unsupported-file", f"{path} is not an HDF5 file (NWB, MATLAB v7.3 or .h5)")
    items = []
    with h5py.File(path, "r") as f:
        def entry(node_path: str, node) -> dict:
            item = {"path": node_path, "name": node_path.rsplit("/", 1)[-1] or "/"}
            attributes = _attributes(node)
            if "neurodata_type" in attributes:
                item["neurodataType"] = attributes["neurodata_type"]
            if isinstance(node, h5py.Dataset):
                item.update(kind="dataset", shape=list(node.shape), dataType=data_type(node.dtype))
                if node.shape == ():
                    try:
                        value = _plain(node[()])
                    except (OSError, TypeError, ValueError):
                        value = None
                    if value is not None:
                        item["value"] = value
            else:
                item["kind"] = "group"
            item["attributes"] = attributes
            return item

        def walk(group, group_path: str):
            for name in group.keys():
                child_path = f"{group_path.rstrip('/')}/{name}"
                link = group.get(name, getlink=True)
                if isinstance(link, h5py.SoftLink):
                    items.append({"path": child_path, "name": name, "kind": "link", "target": link.path})
                elif isinstance(link, h5py.ExternalLink):
                    items.append({"path": child_path, "name": name, "kind": "link", "target": f"{link.filename}:{link.path}"})
                else:
                    node = group[name]
                    items.append(entry(child_path, node))
                    if isinstance(node, h5py.Group):
                        walk(node, child_path)

        items.append(entry("/", f))
        walk(f, "/")
    items.sort(key=lambda item: (item["path"] != "/", item["path"]))
    return {"format": "hdf5", "items": items[:limit], "truncated": len(items) > limit}
