"""The layout of an HDF5 file (NWB, MATLAB v7.3, .h5) for files.inspect: its groups, datasets and links."""
from __future__ import annotations

import re
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


def field_name(name: str, taken) -> str:
    """A dict key (and MATLAB struct field) for the name of an HDF5 member or attribute, the same in both languages
    (nansen.internal.hdf5FieldName): characters other than ASCII letters, digits and _ as _, x before a name that does
    not start with a letter, at most 63 characters (MATLAB's namelengthmax), and _2, _3, ... after one already taken."""
    out = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if not re.match(r"[A-Za-z]", out):
        out = "x" + out
    base = out = out[:63]
    number = 2
    while out in taken:
        suffix = f"_{number}"
        out = base[:63 - len(suffix)] + suffix
        number += 1
    return out


def _value(value):
    """A value as h5py reads it, a string as str."""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def _add_attributes(out: dict, node, prefix: str = "") -> None:
    """A node's attributes, in name order, as out's keys (prefix_ before each, for a dataset's in its group); those
    that hold object references are left out."""
    import h5py

    for name in sorted(node.attrs.keys()):
        if h5py.check_ref_dtype(node.attrs.get_id(name).dtype) is not None:
            continue
        try:
            value = node.attrs[name]
        except (OSError, TypeError, ValueError):
            continue   # a type h5py cannot read
        out[field_name(prefix + name, out)] = _value(value)


def _read_group(group) -> dict:
    import h5py

    out: dict = {}
    _add_attributes(out, group)
    for name in sorted(group.keys()):
        link = group.get(name, getlink=True)
        if isinstance(link, h5py.SoftLink):
            out[field_name(name, out)] = link.path
            continue
        if isinstance(link, h5py.ExternalLink):
            out[field_name(name, out)] = f"{link.filename}:{link.path}"
            continue
        member = group[name]
        if isinstance(member, h5py.Group):
            out[field_name(name, out)] = _read_group(member)
        else:
            out[field_name(name, out)] = _value(member[()])
            _add_attributes(out, member, name + "_")
    return out


def read_group(path: Path, group: str):
    """A group of an HDF5 file as a dict, for files.send (dev's file viewer's NWB node Assign to Workspace gave a MatNWB
    object of it): the group's attributes in name order, then its members in name order: a dataset's value (as
    read_dataset reads it) followed by its attributes, as <dataset>_<attribute> (as MatNWB names them: data_unit), a
    group as a dict of its own, the same way, and a link as the path it points to (file:path for another file's).
    Keys are made by field_name. Returns the dict and its keys; invalid-params when the file has no group there."""
    try:
        import h5py
    except ImportError:
        raise NansenError("dependency-missing", "Reading HDF5 files needs h5py: pip install h5py") from None
    if not h5py.is_hdf5(str(path)):
        raise NansenError("unsupported-file", f"{path} is not an HDF5 file (NWB, MATLAB v7.3 or .h5)")
    with h5py.File(path, "r") as f:
        node = f.get(group)
        if not isinstance(node, h5py.Group):
            raise NansenError("invalid-params", f"{path.name} has no group {group}")
        value = _read_group(node)
    return value, list(value)


def is_group(path: Path, node: str) -> bool:
    """Whether the HDF5 file has a group at that path (False for a dataset, nothing or a file that is not HDF5)."""
    import h5py

    if not h5py.is_hdf5(str(path)):
        return False
    with h5py.File(path, "r") as f:
        return isinstance(f.get(node), h5py.Group)


def read_dataset(path: Path, dataset: str):
    """One dataset of an HDF5 file as h5py reads it (an array in the file's order; a string as str), its shape in the
    file's order and its type's name, for files.send; invalid-params when the file has no dataset at that path."""
    try:
        import h5py
    except ImportError:
        raise NansenError("dependency-missing", "Reading HDF5 files needs h5py: pip install h5py") from None
    if not h5py.is_hdf5(str(path)):
        raise NansenError("unsupported-file", f"{path} is not an HDF5 file (NWB, MATLAB v7.3 or .h5)")
    with h5py.File(path, "r") as f:
        node = f.get(dataset)
        if not isinstance(node, h5py.Dataset):
            raise NansenError("invalid-params", f"{path.name} has no dataset {dataset}")
        value = node[()]
        if isinstance(value, bytes):
            value = value.decode("utf-8", "replace")
        return value, list(node.shape), data_type(node.dtype)
