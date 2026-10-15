"""Frames of image data for the dashboard's viewer: one frame or a projection, scaled to 8 bits.

MATLAB's nansen.internal.imageFrame computes the same bytes from the same array, so both backends draw
the same picture.
"""

from __future__ import annotations

import base64
import math
from typing import Any, Dict, List, Optional

from .errors import NansenError


def image_frame(data: Any, frame: int = 0, channel: int = 0, projection: Optional[str] = None,
                limits: Optional[List[float]] = None, plane: int = 0) -> Dict[str, Any]:
    """A frame of a height x width (x frames), height x width x channels x frames or height x width x channels x
    planes x frames array or stack (nansen.stacks.Stack, read a chunk of frames at a time), as 8-bit values.

    Values from low to high are scaled to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at
    both ends; NaN is 0. low and high are the limits given, or else the smallest and largest finite value
    of the frame. pixels is base64 of the bytes, row after row.
    """
    try:
        import numpy as np
    except ImportError:
        raise NansenError("adapter-unavailable", 'viewing arrays needs NumPy: pip install "nansen-core[npy]"') from None
    from .stacks import Stack, from_array
    stack = data if isinstance(data, Stack) else None
    if stack is None:
        array = np.asarray(data)
        if array.dtype.kind not in "biuf" or not 2 <= array.ndim <= 5:
            raise NansenError("invalid-data", "the data is not an image or a stack of images")
        stack = from_array(array[:, :, None] if array.ndim == 2 else array)
    elif stack.ndim == 2:
        stack.max_frames = None   # an image's columns are not frames
        stack = from_array(np.asarray(stack)[:, :, None])
    if stack.dtype.kind not in "biuf" or not 3 <= stack.ndim <= 5:
        raise NansenError("invalid-data", "the data is not an image or a stack of images")
    if stack.ndim == 5:
        if not 0 <= plane < stack.shape[3]:
            raise NansenError("invalid-params", f"there are {stack.shape[3]} planes; plane {plane} is not one")
        stack = stack.select(slice(None), slice(None), slice(None), plane)
    elif plane != 0:
        raise NansenError("invalid-params", f"there is 1 plane; plane {plane} is not one")
    if stack.ndim == 4:
        if not 0 <= channel < stack.shape[2]:
            raise NansenError("invalid-params", f"there are {stack.shape[2]} channels; channel {channel} is not one")
        stack = stack.select(slice(None), slice(None), channel)
    height, width, frames = stack.shape
    chunk = 100   # frames read at a time for a projection
    if projection == "mean":
        total = np.zeros((height, width))
        for start in range(0, frames, chunk):
            total += stack.frames(start, start + chunk).astype(np.float64).sum(axis=2)
        image, frame = total / frames, None
    elif projection == "max":
        image = None
        for start in range(0, frames, chunk):
            peak = stack.frames(start, start + chunk).max(axis=2)
            image = peak if image is None else np.maximum(image, peak)
        image, frame = image.astype(np.float64), None
    elif projection is None:
        if not 0 <= frame < frames:
            raise NansenError("invalid-params", f"there are {frames} frames; frame {frame} is not one")
        image = stack.frames(frame, frame + 1)[:, :, 0].astype(np.float64)
    else:
        raise NansenError("invalid-params", f"projection is mean or max, not {projection!r}")
    if limits is not None:
        low, high = float(limits[0]), float(limits[1])
    else:
        finite = image[np.isfinite(image)]
        low, high = (float(finite.min()), float(finite.max())) if finite.size else (0.0, 0.0)
    scaled = np.zeros((height, width), dtype=np.uint8)
    if high > low:
        with np.errstate(invalid="ignore"):
            values = np.floor((image - low) / (high - low) * 255 + 0.5)
        scaled = np.clip(np.nan_to_num(values, nan=0.0), 0, 255).astype(np.uint8)
    return {"height": height, "width": width, "frames": frames, "frame": frame, "low": _number(low), "high": _number(high),
            "pixels": base64.b64encode(scaled.tobytes()).decode("ascii")}


def roi_outlines(value: Any) -> List[Dict[str, Any]]:
    """The ROIs of an ROI file ({rois: [{id?, pixels: [[row, column], ...]}]}, 0-based) as the viewer draws them."""
    if not isinstance(value, dict) or not isinstance(value.get("rois", []), list):
        raise NansenError("invalid-data", "the ROIs are not a JSON object with a list of rois")
    out = []
    for number, roi in enumerate(value.get("rois", []), start=1):
        pixels = roi.get("pixels", []) if isinstance(roi, dict) else []
        if pixels and not isinstance(pixels[0], list):
            pixels = [pixels]
        out.append({"id": roi.get("id", number), "pixels": [[int(p[0]), int(p[1])] for p in pixels],
                    "classification": roi.get("classification")})
    return out


CLASSES = ("accepted", "rejected")


def update_rois(value: Any, classify: Optional[list] = None, remove: Optional[list] = None,
                add: Optional[list] = None) -> Any:
    """The ROI file with ROIs classified, removed and added; returns (document, ids of the added ROIs).

    classify is [{id, classification}] with classification accepted, rejected or null (none). An added ROI is
    {pixels}; it gets the next free id, its area and its center, and pixels outside imageSize are left out.
    """
    roi_outlines(value)  # checks the shape
    rois = [dict(roi, id=roi.get("id", number)) for number, roi in enumerate(value.get("rois", []), start=1)]
    by_id = {roi["id"]: roi for roi in rois}
    for change in classify or []:
        roi = by_id.get(change.get("id"))
        if roi is None:
            raise NansenError("invalid-params", f"there is no ROI {change.get('id')!r}")
        label = change.get("classification")
        if label is None:
            roi.pop("classification", None)
        elif label in CLASSES:
            roi["classification"] = label
        else:
            raise NansenError("invalid-params", f"an ROI is accepted or rejected, not {label!r}")
    for roi_id in remove or []:
        if roi_id not in by_id:
            raise NansenError("invalid-params", f"there is no ROI {roi_id!r}")
    rois = [roi for roi in rois if roi["id"] not in set(remove or [])]
    size = value.get("imageSize")
    next_id = max([int(i) for i in by_id] + [0]) + 1
    added = []
    for new in add or []:
        pixels = sorted({(int(p[0]), int(p[1])) for p in new.get("pixels", [])
                         if size is None or (0 <= p[0] < size[0] and 0 <= p[1] < size[1])})
        if not pixels:
            raise NansenError("invalid-params", "an added ROI needs pixels inside the image")
        rows = sum(p[0] for p in pixels) / len(pixels)
        columns = sum(p[1] for p in pixels) / len(pixels)
        rois.append({"id": next_id, "area": len(pixels), "center": [_round2(rows), _round2(columns)],
                     "pixels": [list(p) for p in pixels]})
        added.append(next_id)
        next_id += 1
    return dict(value, rois=rois), added


def _round2(value: float) -> float:
    return math.floor(value * 100 + 0.5) / 100


def _number(value: float):
    return int(value) if math.isfinite(value) and value == int(value) else value
