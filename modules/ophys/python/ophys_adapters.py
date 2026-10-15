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
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        """The recording as a stack read frame by frame from the file (a memory map); several files are joined."""
        from nansen.stacks import join, natural_order
        return join([self._open_one(Path(p)) for p in natural_order(paths)])

    def _open_one(self, path):
        from nansen.stacks import Stack
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
        mapped = np.memmap(path, dtype=dtype, mode="r", shape=(frames, channels, height, width)) if frames else None
        native = dtype.newbyteorder("=")

        def read(start, stop):
            data = np.asarray(mapped[start:stop]).astype(native).transpose(2, 3, 1, 0)
            return data[:, :, 0, :] if channels == 1 else data

        shape = (height, width, frames) if channels == 1 else (height, width, channels, frames)
        return Stack(shape, native, read)

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
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        """The pages of the files, in natural order, as one stack read page by page."""
        from nansen.stacks import Stack, natural_order, pages
        tifffile = _tifffile()
        paths = [str(p) for p in natural_order(paths)]
        with tifffile.TiffFile(paths[0]) as tif:
            first = tif.pages[0]
            if len(first.shape) != 2:
                raise NansenError("invalid-data", f"{paths[0]} holds pages of {first.shape}; a TIFF stack of grayscale frames is read")
            frame_shape, dtype = tuple(first.shape), first.dtype
        count, read_pages = pages(paths, _page_info, _read_pages, frame_shape, dtype)
        return Stack(frame_shape + (count,), dtype, lambda start, stop: np.moveaxis(read_pages(start, stop), 0, 2))

    def write(self, path, data):
        tifffile = _tifffile()
        data = np.asarray(data)
        if data.ndim == 2:
            data = data[:, :, None]
        if data.ndim != 3 or data.dtype.kind not in "uif" or data.dtype.itemsize > 4 and data.dtype.kind != "f":
            raise NansenError("invalid-params", "a TIFF stack is height x width x frames of integers or floats")
        tifffile.imwrite(str(path), np.moveaxis(data, 2, 0), photometric="minisblack")


class ScanImageTiff:
    """A ScanImage TIFF file: frames of every saved channel, plane after plane, volume after volume.

    The channels (SI.hChannels.channelSave) and planes (SI.hStackManager.numSlices) are read from the
    first page's Software tag, or its ImageDescription for older versions. Reads height x width x frames,
    height x width x channels x frames with more than one channel, and height x width x channels x planes x
    frames with more than one plane. A multi-ROI recording (SI.hRoiManager.mroiEnable) has its ROIs one above
    the other on each page, with flyback lines between them, and their sizes in the Artist tag: the ROIs are
    put side by side, padded with 0 at the bottom to the tallest. Pages after the last whole volume are left out.
    """

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        """The recording as a stack read volume by volume; ScanImage's files of one recording are joined, their
        pages one sequence (a volume may begin in one file and end in the next)."""
        from nansen.stacks import Stack, natural_order, pages
        tifffile = _tifffile()
        paths = [str(p) for p in natural_order(paths)]
        with tifffile.TiffFile(paths[0]) as tif:
            first = tif.pages[0]
            text = "\n".join(str(first.tags[name].value) for name in ("Software", "ImageDescription") if name in first.tags)
            artist = str(first.tags["Artist"].value) if "Artist" in first.tags else ""
            height, width = first.shape[:2]
            dtype = first.dtype
        if "SI." not in text:
            raise NansenError("invalid-data", f"{paths[0]} is not a ScanImage TIFF file (no SI. metadata)")
        channels = len(si_numbers(text, "hChannels.channelSave")) or 1
        planes = int((si_numbers(text, "hStackManager.actualNumSlices") or si_numbers(text, "hStackManager.numSlices") or [1])[0])
        mosaic = bool((si_numbers(text, "hRoiManager.mroiEnable") or [0])[0] and artist)
        count, read_pages = pages(paths, _page_info, _read_pages, (height, width), dtype)
        volumes = count // (channels * planes)   # pages after the last whole volume are left out

        def read(start, stop):
            data = read_pages(start * channels * planes, stop * channels * planes)
            data = data.reshape(stop - start, planes, channels, height, width).transpose(3, 4, 2, 1, 0)
            if mosaic:
                data = mroi_mosaic(data, artist, paths[0])
            if planes == 1:
                data = data[:, :, :, 0, :]
                if channels == 1:
                    data = data[:, :, 0, :]
            return data

        probe = read(0, 1) if volumes else read(0, 0)
        return Stack(probe.shape[:-1] + (volumes,), dtype, read)

    def write(self, path, data):
        raise NansenError("invalid-params", "ScanImage files are written by ScanImage; save a stack with npy or ophys.tiff_stack")


def si_numbers(text, name):
    """The numbers of the SI.<name> = value line of ScanImage metadata (true is 1, false 0); [] if there is none."""
    match = re.search(r"(?:^|\n)\s*(?:scanimage\.)?SI\." + re.escape(name) + r"\s*=\s*([^\n]*)", text)
    if not match:
        return []
    value = match.group(1).replace("true", "1").replace("false", "0")
    return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", value)]


def mroi_mosaic(data, artist, path):
    """The ROIs of a multi-ROI recording side by side: ROI k is rows sum(h_1..h_(k-1)) + k-1 flyback gaps on."""
    import json

    try:
        rois = json.loads(artist)["RoiGroups"]["imagingRoiGroup"]["rois"]
    except (ValueError, KeyError, TypeError):
        raise NansenError("invalid-data", f"{path} has no multi-ROI layout in its Artist tag") from None
    rois = rois if isinstance(rois, list) else [rois]
    sizes = []
    for roi in rois:
        field = roi["scanfields"][0] if isinstance(roi["scanfields"], list) else roi["scanfields"]
        sizes.append([int(v) for v in field["pixelResolutionXY"]])  # [width, height]
    height = data.shape[0]
    gap = (height - sum(h for _, h in sizes)) // (len(sizes) - 1) if len(sizes) > 1 else 0
    out = np.zeros((max(h for _, h in sizes), sum(min(w, data.shape[1]) for w, _ in sizes)) + data.shape[2:], dtype=data.dtype)
    top, left = 0, 0
    for w, h in sizes:
        w = min(w, data.shape[1])
        out[:h, left:left + w] = data[top:top + h, :w]
        top += h + gap
        left += w
    return out


def _page_info(path):
    """A TIFF file's page count, and its first page's shape and type."""
    with _tifffile().TiffFile(str(path)) as tif:
        return len(tif.pages), tuple(tif.pages[0].shape), tif.pages[0].dtype


def _read_pages(path, start, stop):
    with _tifffile().TiffFile(str(path)) as tif:
        return np.stack([tif.pages[i].asarray() for i in range(start, stop)], axis=0)


def _tifffile():
    try:
        import tifffile
    except ImportError:
        raise NansenError("adapter-unavailable", 'TIFF stacks need tifffile: pip install "nansen-core[ophys]"') from None
    return tifffile
