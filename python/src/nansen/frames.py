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
                limits: Optional[List[float]] = None) -> Dict[str, Any]:
    """A frame of a height x width (x frames) or height x width x channels x frames array, as 8-bit values.

    Values from low to high are scaled to 0..255 as floor((v - low) / (high - low) * 255 + 0.5), cut at
    both ends; NaN is 0. low and high are the limits given, or else the smallest and largest finite value
    of the frame. pixels is base64 of the bytes, row after row.
    """
    try:
        import numpy as np
    except ImportError:
        raise NansenError("adapter-unavailable", 'viewing arrays needs NumPy: pip install "nansen-core[npy]"') from None
    array = np.asarray(data)
    if array.dtype.kind not in "biuf" or not 2 <= array.ndim <= 4:
        raise NansenError("invalid-data", "the data is not an image or a stack of images")
    if array.ndim == 4:
        if not 0 <= channel < array.shape[2]:
            raise NansenError("invalid-params", f"there are {array.shape[2]} channels; channel {channel} is not one")
        array = array[:, :, channel, :]
    if array.ndim == 2:
        array = array[:, :, None]
    height, width, frames = array.shape
    if projection == "mean":
        image, frame = array.astype(np.float64).mean(axis=2), None
    elif projection == "max":
        image, frame = array.max(axis=2).astype(np.float64), None
    elif projection is None:
        if not 0 <= frame < frames:
            raise NansenError("invalid-params", f"there are {frames} frames; frame {frame} is not one")
        image = array[:, :, frame].astype(np.float64)
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
        out.append({"id": roi.get("id", number), "pixels": [[int(p[0]), int(p[1])] for p in pixels]})
    return out


def _number(value: float):
    return int(value) if math.isfinite(value) and value == int(value) else value
