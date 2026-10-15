"""File adapters of the ophys module: SciScan raw recordings and TIFF stacks, as height x width x frames."""

import re
from pathlib import Path

import numpy as np

from nansen.errors import NansenError

SCISCAN_TYPES = {0: ">u2", 1: ">f4"}  # file.format in the .ini file


def read_ini(path):
    """The name = value lines of a SciScan .ini file, values stripped of quotes."""
    values = {}
    for line in Path(path).read_text(encoding="latin-1").splitlines():
        match = re.match(r'^\s*([^=\[;]+?)\s*=\s*"?(.*?)"?\s*$', line)
        if match:
            values.setdefault(match.group(1), match.group(2))
    return values


def ini_number(values, name, path):
    try:
        return float(values[name].replace(",", "."))
    except (KeyError, ValueError):
        raise NansenError("invalid-data", f"{path} has no number {name}") from None


class SciScanRaw:
    """A SciScan .raw file with the .ini file of the same name beside it.

    Frames follow each other, with the channels of a frame one after the other; each channel is
    x.pixels values per line, line after line, big-endian. Reads height x width x frames, or height x
    width x channels x frames when no.of.channels is more than 1. Frames are counted from the file size
    when the .ini file does not give no.of.frames.acquired, and an incomplete last frame is left out.
    """

    def read(self, path):
        path = Path(path)
        ini = path.with_suffix(".ini")
        if not ini.is_file():
            raise NansenError("invalid-data", f"{path} has no {ini.name} beside it")
        values = read_ini(ini)
        width = int(ini_number(values, "x.pixels", ini))
        height = int(ini_number(values, "y.pixels", ini))
        channels = int(ini_number(values, "no.of.channels", ini)) if "no.of.channels" in values else 1
        kind = int(ini_number(values, "file.format", ini))
        if kind not in SCISCAN_TYPES:
            raise NansenError("invalid-data", f"{ini} has file.format {kind}; 0 (16-bit) and 1 (32-bit float) are read")
        dtype = np.dtype(SCISCAN_TYPES[kind])
        per_frame = width * height * channels
        frames = path.stat().st_size // (per_frame * dtype.itemsize)
        if "no.of.frames.acquired" in values:
            frames = min(frames, int(ini_number(values, "no.of.frames.acquired", ini)))
        data = np.fromfile(path, dtype=dtype, count=frames * per_frame).astype(dtype.newbyteorder("="))
        data = data.reshape(frames, channels, height, width).transpose(2, 3, 1, 0)
        return np.ascontiguousarray(data[:, :, 0, :] if channels == 1 else data)

    def write(self, path, data):
        data = np.asarray(data)
        if data.dtype == np.uint16:
            kind = 0
        elif data.dtype == np.float32:
            kind = 1
        else:
            raise NansenError("invalid-params", f"SciScan raw files hold uint16 or float32 values, not {data.dtype}")
        if data.ndim == 2:
            data = data[:, :, None]
        if data.ndim == 3:
            data = data[:, :, None, :]
        if data.ndim != 4:
            raise NansenError("invalid-params", "a SciScan stack is height x width x frames, or height x width x channels x frames")
        height, width, channels, frames = data.shape
        path = Path(path)
        data.transpose(3, 2, 0, 1).astype(SCISCAN_TYPES[kind]).tofile(path)
        lines = [f"x.pixels = {width}", f"y.pixels = {height}", f"no.of.channels = {channels}",
                 f"no.of.frames.acquired = {frames}", f"file.format = {kind}"]
        lines += [f'save.ch.{n + 1} = "TRUE"' for n in range(channels)]
        path.with_suffix(".ini").write_text("[_]\n" + "\n".join(lines) + "\n", encoding="latin-1")


class TiffStack:
    """A multi-page grayscale TIFF file, as height x width x frames (needs tifffile)."""

    def read(self, path):
        tifffile = _tifffile()
        data = np.asarray(tifffile.imread(str(path)))
        if data.ndim == 2:
            return data[:, :, None]
        if data.ndim != 3:
            raise NansenError("invalid-data", f"{path} holds {data.shape}; a TIFF stack of grayscale frames is read")
        return np.ascontiguousarray(np.moveaxis(data, 0, 2))

    def write(self, path, data):
        tifffile = _tifffile()
        data = np.asarray(data)
        if data.ndim == 2:
            data = data[:, :, None]
        if data.ndim != 3 or data.dtype.kind not in "uif" or data.dtype.itemsize > 4 and data.dtype.kind != "f":
            raise NansenError("invalid-params", "a TIFF stack is height x width x frames of integers or floats")
        tifffile.imwrite(str(path), np.moveaxis(data, 2, 0), photometric="minisblack")


def _tifffile():
    try:
        import tifffile
    except ImportError:
        raise NansenError("adapter-unavailable", 'TIFF stacks need tifffile: pip install "nansen-core[ophys]"') from None
    return tifffile
