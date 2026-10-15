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


DEV_CLASSES = {"uint8": "u1", "int8": "i1", "uint16": "<u2", "int16": "<i2", "uint32": "<u4", "int32": "<i4",
               "uint64": "<u8", "int64": "<i8", "single": "<f4", "double": "<f8", "logical": "?"}


class BinaryStack:
    """NANSEN dev's own image stack file (its Binary stack): a headerless .raw (or .bin, .dat) and an .ini of the same
    name with two lines, "Size = 512   512  1000" and "Class = uint16". The values are in MATLAB's column-major
    order (rows fastest, then columns, channels, planes and frames), little-endian. A .raw whose .ini is
    SciScan's is read as SciScan's (ophys.sciscan_raw), so this adapter reads every .raw a dev project has.
    Read a chunk of frames at a time; written in the same format, which dev reads."""

    extensions = [".raw", ".bin", ".dat"]

    @staticmethod
    def info(path):
        """(size, dtype) from the .ini file; None when it is SciScan's."""
        ini = Path(path).with_suffix(".ini")
        if not ini.is_file():
            raise NansenError("invalid-data", f"{path}: there is no {ini.name} beside it")
        values = {}
        for line in ini.read_text(errors="replace").splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"')
        if "Size" not in values or "Class" not in values:
            if "x.pixels" in values:
                return None
            raise NansenError("invalid-data", f"{ini} has no Size and Class (not a NANSEN dev binary stack)")
        if values["Class"] not in DEV_CLASSES:
            raise NansenError("invalid-data", f"{ini}: class {values['Class']!r} is not one this adapter reads")
        size = tuple(int(float(v)) for v in values["Size"].split())
        return size, np.dtype(DEV_CLASSES[values["Class"]])

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import from_array, join, natural_order
        parts = []
        for path in natural_order(paths):
            found = self.info(path)
            if found is None:
                parts.append(SciScanRaw().open([path]))
                continue
            size, dtype = found
            expected = int(np.prod(size)) * dtype.itemsize
            if Path(path).stat().st_size < expected:
                raise NansenError("invalid-data", f"{path} is {Path(path).stat().st_size} bytes; Size {list(size)} of {dtype} needs {expected}")
            parts.append(from_array(np.memmap(path, dtype=dtype, mode="r", shape=size, order="F")))
        return join(parts)

    def write(self, path, data):
        data = np.asarray(data)
        self._ini(path, data.shape, data.dtype)
        data.astype(self._disk(data.dtype)).ravel(order="F").tofile(path)

    def create(self, path, shape, dtype):
        """A writer of a new stack, a chunk of frames at a time, straight into the file."""
        from nansen.stacks import StackWriter
        dtype = np.dtype(dtype)
        self._ini(path, shape, dtype)
        target = np.memmap(path, dtype=self._disk(dtype), mode="w+", shape=tuple(int(n) for n in shape), order="F")
        return StackWriter(shape, dtype, target=target)

    @staticmethod
    def _disk(dtype):
        name = next((n for n, code in DEV_CLASSES.items() if np.dtype(code) == np.dtype(dtype).newbyteorder("<")), None)
        if name is None:
            raise NansenError("invalid-params", f"a NANSEN dev binary stack holds no {np.dtype(dtype)} values")
        return np.dtype(DEV_CLASSES[name])

    @classmethod
    def _ini(cls, path, shape, dtype):
        name = next(n for n, code in DEV_CLASSES.items() if np.dtype(code) == cls._disk(dtype))
        size = "  ".join(str(int(n)) for n in shape)
        Path(path).with_suffix(".ini").write_text(f"Size = {size}\nClass = {name}\n")


class Suite2pBinary:
    """suite2p's registered recording, data.bin: int16 frames, each Ly x Lx in C order, one after the other, with
    Ly and Lx in the ops.npy beside it. Read a chunk of frames at a time. ops.npy is a pickled dict: its Ly and Lx
    are found in the pickle's bytes (suite2p keeps them as plain integers), and nothing in it is unpickled, so a
    file cannot run code. Read only; frames past the last whole one are left out."""

    extensions = [".bin"]

    @staticmethod
    def frame_size(path):
        """(Ly, Lx) from the ops.npy beside a data.bin."""
        ops = Path(path).with_name("ops.npy")
        if not ops.is_file():
            raise NansenError("invalid-data", f"{path}: there is no ops.npy beside it, which has the frame size")
        data = ops.read_bytes()
        return tuple(_pickled_int(data, key, ops) for key in ("Ly", "Lx"))

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import from_array, join, natural_order
        parts = []
        for path in natural_order(paths):
            ly, lx = self.frame_size(path)
            frames = Path(path).stat().st_size // (2 * ly * lx)
            if frames == 0:
                raise NansenError("invalid-data", f"{path} holds no whole {ly} x {lx} frame of int16")
            stored = np.memmap(path, dtype="<i2", mode="r", shape=(frames, ly, lx))
            parts.append(from_array(np.moveaxis(stored, 0, 2)))
        return join(parts)

    def write(self, path, data):
        raise NansenError("invalid-params", "suite2p's files are written by suite2p; save stacks in another format")


def _pickled_int(data, key, path):
    """The plain integer stored under a string key of a pickled dict, read from the pickle's opcodes: the key as
    SHORT_BINUNICODE (protocol 4 and up) or BINUNICODE (protocols 1 to 3), an optional memo opcode, then BININT1,
    BININT2, BININT or LONG1."""
    name = key.encode()
    for prefix in (b"\x8c" + bytes([len(name)]), b"X" + len(name).to_bytes(4, "little")):
        at = data.find(prefix + name)
        if at < 0:
            continue
        i = at + len(prefix) + len(name)
        skip = {0x94: 1, ord("q"): 2, ord("r"): 5}   # MEMOIZE, BINPUT, LONG_BINPUT
        if data[i] in skip:
            i += skip[data[i]]
        code = data[i]
        if code == ord("K"):
            return data[i + 1]
        if code == ord("M"):
            return int.from_bytes(data[i + 1:i + 3], "little")
        if code == ord("J"):
            return int.from_bytes(data[i + 1:i + 5], "little", signed=True)
        if code == 0x8A:   # LONG1
            return int.from_bytes(data[i + 2:i + 2 + data[i + 1]], "little", signed=True)
        raise NansenError("invalid-data", f"{path}: {key} is not a plain integer")
    raise NansenError("invalid-data", f"{path} has no {key}")


class VideoFile:
    """A video file, as dev's Video stack reads one: uint8 frames, height x width x frames, or height x width x 3 x
    frames (red, green, blue as channels) when it has colour. A video whose first frame has the same red, green
    and blue is read as grayscale, so the two languages' decoders agree (ffmpeg always gives colour). Read a chunk
    of frames at a time with imageio and its ffmpeg (the video extra); read only."""

    extensions = [".avi", ".mp4", ".mov", ".mkv", ".mj2"]

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import Stack, join, natural_order
        iio = _imageio()
        parts = []
        for path in natural_order(paths):
            path = str(path)
            with iio.get_reader(path, format="ffmpeg") as reader:
                count = reader.count_frames()
                first = np.asarray(reader.get_data(0))
            if first.ndim == 2:
                first = first[:, :, None]
            gray = first.shape[2] == 1 or bool((first[:, :, 0] == first[:, :, 1]).all() and (first[:, :, 1] == first[:, :, 2]).all())
            height, width = first.shape[:2]

            def frames(start, stop, path=path, gray=gray):
                with iio.get_reader(path, format="ffmpeg") as reader:
                    chunk = np.stack([np.asarray(reader.get_data(i)) for i in range(start, stop)], axis=-1) if stop > start else \
                        np.zeros((height, width, 3, 0), np.uint8)
                if chunk.ndim == 3:   # one channel decoded
                    chunk = chunk[:, :, None, :]
                return chunk[:, :, 0, :] if gray else chunk[:, :, :3, :]

            parts.append(Stack((height, width, count) if gray else (height, width, 3, count), np.uint8, frames))
        return join(parts)

    def write(self, path, data):
        raise NansenError("invalid-params", "video files are read only; save stacks as TIFF or another format")


def _imageio():
    try:
        import imageio.v2 as iio
        import imageio_ffmpeg  # noqa: F401
    except ImportError:
        raise NansenError("adapter-unavailable", 'video files need imageio and imageio-ffmpeg: pip install "nansen-core[video]"') from None
    return iio


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

    def create(self, path, shape, dtype):
        """A writer of a new TIFF stack, a chunk of frames at a time, each frame a page; frames come in order."""
        return TiffPageWriter(path, shape, dtype)


class TsmStack:
    """A TSM file (SciMeasure / RedShirt cameras, dev's macroscope recordings): a FITS-like header of 80-character
    cards in 2880-byte blocks (NAXIS1 columns, NAXIS2 rows, NAXIS3 frames), then int16 frames, little-endian, the
    columns fastest, then a dark frame, which is subtracted from every frame (saturating at int16's range), as dev's
    TSM stack does. Read a chunk at a time; read only."""

    extensions = [".tsm"]

    @staticmethod
    def header(path):
        """(columns, rows, frames, offset of the data) from the header cards."""
        values, offset = {}, 0
        with open(path, "rb") as f:
            while True:
                block = f.read(2880)
                if len(block) < 2880:
                    raise NansenError("invalid-data", f"{path} ends inside its header (no END card)")
                offset += 2880
                cards = [block[i:i + 80].decode("ascii", "replace") for i in range(0, 2880, 80)]
                for card in cards:
                    key = card[:8].strip()
                    if key == "END":
                        break
                    if card[8:10] == "= ":
                        values[key] = card[10:].split("/")[0].strip()
                else:
                    continue
                break
        try:
            columns, rows, frames = (int(values[k]) for k in ("NAXIS1", "NAXIS2", "NAXIS3"))
        except (KeyError, ValueError):
            raise NansenError("invalid-data", f"{path} has no NAXIS1, NAXIS2 and NAXIS3") from None
        return columns, rows, frames, offset

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import Stack, join, natural_order
        parts = []
        for path in natural_order(paths):
            columns, rows, frames, offset = self.header(path)
            needed = offset + (frames + 1) * rows * columns * 2
            if Path(path).stat().st_size < needed:
                raise NansenError("invalid-data", f"{path} is {Path(path).stat().st_size} bytes; {frames} frames and a dark frame of {rows} x {columns} need {needed}")
            data = np.memmap(path, dtype="<i2", mode="r", offset=offset, shape=(frames + 1, rows, columns))
            dark = np.asarray(data[frames], dtype=np.int32)

            def read(start, stop, data=data, dark=dark):
                chunk = np.asarray(data[start:stop], dtype=np.int32) - dark
                return np.moveaxis(np.clip(chunk, -32768, 32767).astype(np.int16), 0, 2)

            parts.append(Stack((rows, columns, frames), np.int16, read))
        return join(parts)

    def write(self, path, data):
        raise NansenError("invalid-params", "TSM files are written by the camera; save stacks as TIFF")


class ThorLabsTiffs:
    """A ThorImage recording: a TIFF file per frame and channel, named ChanA_001_001_001_0001.tif and so on, as dev's
    ThorLabsTiffs reads them. The files of each channel letter are its frames, in natural order; with more than
    one channel the stack is height x width x channels x frames, channels in letter order. Read a chunk at a time."""

    extensions = [".tif", ".tiff"]

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import Stack
        groups = {}
        for path in paths:
            match = re.match(r"Chan([A-Z])_", Path(path).name)
            if not match:
                raise NansenError("invalid-data", f"{Path(path).name} is not a ThorImage frame (ChanA_..., ChanB_...)")
            groups.setdefault(match.group(1), []).append(path)
        channels = [TiffStack().open(groups[letter]) for letter in sorted(groups)]
        if len(channels) == 1:
            return channels[0]
        first = channels[0]
        if any(c.shape != first.shape or c.dtype != first.dtype for c in channels):
            raise NansenError("invalid-data", "the channels of the recording differ in size, frames or type")
        height, width, frames = first.shape
        return Stack((height, width, len(channels), frames), first.dtype,
                     lambda start, stop: np.stack([c.frames(start, stop) for c in channels], axis=2))

    def write(self, path, data):
        raise NansenError("invalid-params", "ThorImage files are written by ThorImage; save stacks as TIFF")


class TiffPageWriter:
    """Writes a height x width x frames stack to a TIFF file a chunk of frames at a time, as nansen.stacks.StackWriter
    does for other files: write(start, chunk), close(). Frames must come in order; BigTIFF from 4 GB."""

    def __init__(self, path, shape, dtype):
        tifffile = _tifffile()
        self.shape = tuple(int(n) for n in shape)
        self.dtype = np.dtype(dtype)
        if len(self.shape) != 3 or self.dtype.kind not in "uif":
            raise NansenError("invalid-params", "a TIFF stack is height x width x frames of integers or floats")
        self.written = 0
        self._writer = tifffile.TiffWriter(str(path), bigtiff=int(np.prod(self.shape)) * self.dtype.itemsize > 4e9)

    def write(self, start, chunk):
        chunk = np.asarray(chunk)
        if chunk.ndim == 2:
            chunk = chunk[:, :, None]
        if int(start) != self.written or chunk.shape[:2] != self.shape[:2] or self.written + chunk.shape[2] > self.shape[2]:
            raise NansenError("invalid-params", f"a {chunk.shape} chunk at frame {start} does not follow the {self.written} frames of a {self.shape} TIFF stack")
        for t in range(chunk.shape[2]):
            self._writer.write(chunk[:, :, t].astype(self.dtype, copy=False), photometric="minisblack", contiguous=True)
        self.written += chunk.shape[2]

    def close(self):
        if self._writer is not None:
            self._writer.close()
            self._writer = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


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


# --- ROI files of other tools, read as the module's ROI document ---------------------------------------------------------
#
# Each reads (read-only) as {imageSize, rois: [{id, area, center, pixels, classification?}]}: ids in file order from 1,
# 0-based [row, column] pixels in row-major order, pixels outside the image left out, center the mean row and
# column rounded to 2 decimals. MATLAB's adapters of the same names read the same.

def roi_document(image_size, rois):
    """The ROI document of a list of (pixels, classification) in file order."""
    height, width = int(image_size[0]), int(image_size[1])
    out = []
    for number, (pixels, classification) in enumerate(rois, start=1):
        kept = sorted({(int(r), int(c)) for r, c in pixels if 0 <= r < height and 0 <= c < width})
        rows = np.array([p[0] for p in kept], dtype=np.float64)
        columns = np.array([p[1] for p in kept], dtype=np.float64)
        roi = {"id": number, "area": len(kept),
               "center": [_round2(rows.mean()) if kept else None, _round2(columns.mean()) if kept else None],
               "pixels": [[r, c] for r, c in kept]}
        if classification:
            roi["classification"] = classification
        out.append(roi)
    return {"imageSize": [height, width], "rois": out}


def _round2(value):
    return float(np.floor(value * 100 + 0.5) / 100)


def _round_away(value):
    """Half away from zero, as MATLAB's round."""
    return int(np.copysign(np.floor(abs(value) + 0.5), value))


def in_polygon(xs, ys, px, py):
    """Even-odd rule: is the point (px, py) inside the polygon of vertices (xs, ys)?"""
    inside = False
    j = len(xs) - 1
    for i in range(len(xs)):
        if (ys[i] > py) != (ys[j] > py) and px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]:
            inside = not inside
        j = i
    return inside


def weights_pixels(weights, threshold=0.2):
    """The 8-connected area around a spatial footprint's peak of pixels weighing at least threshold x the peak's,
    as ophys.extract keeps EXTRACT's cells. The first peak in row-major order, when several are equal."""
    weights = np.asarray(weights, dtype=np.float64)
    if not weights.size or weights.max() <= 0:
        return []
    peak = np.unravel_index(int(np.argmax(weights)), weights.shape)
    above = weights >= threshold * weights[peak]
    area, todo = {peak}, [peak]
    while todo:
        r, c = todo.pop()
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                n = (r + dr, c + dc)
                if 0 <= n[0] < weights.shape[0] and 0 <= n[1] < weights.shape[1] and above[n] and n not in area:
                    area.add(n)
                    todo.append(n)
    return list(area)


def _mat(path):
    from nansen.adapters import MatAdapter
    return MatAdapter().read(Path(path))


DEV_CLASSIFICATIONS = {1: "accepted", 2: "rejected"}   # dev's roiClassification: 0 unclassified, 3 unresolved
DEV_ROI_FIELDS = ["uid", "shape", "coordinates", "pixelweights", "imagesize", "boundary", "area", "center", "connectedrois",
                  "group", "celltype", "structure", "layer", "tags", "enhancedImage"]


class NansenRoiArray:
    """dev's ROI file (.mat): a struct array roiArray (or RoiArray, roi_arr) of RoI properties, as dev's
    roimanager and RoiGroup adapter save them, with roiClassification beside it (1 accepted, 2 rejected; 0
    unclassified and 3 unresolved are left unclassified). Mask and Donut ROIs are their pixels, given as 1-based
    x (column), y (row); IMask ROIs those of weight above 0; Circle ROIs are x, y and a radius, made into pixels as
    dev's RoI does; Polygon ROIs are the pixels whose centre is inside, by the even-odd rule. A file of several
    planes or channels (cells of them) is read as its first. Written as dev's RoiGroup adapter writes: Mask ROIs
    and their classification, which dev reads."""

    extensions = [".mat"]

    def read(self, path):
        data = _mat(path)
        name = next((n for n in ("roiArray", "RoiArray", "roi_arr") if n in data), None)
        if name is None:
            raise NansenError("invalid-data", f"{path} has no roiArray")
        rois, classes = data[name], data.get("roiClassification")
        if _groups(rois):   # planes x channels: the first
            rois = rois[0]
            if isinstance(classes, list) or (isinstance(classes, np.ndarray) and classes.dtype == object):
                classes = classes[0]
        rois = [rois] if isinstance(rois, dict) else list(rois) if rois is not None and np.size(rois) else []
        rois = [_plain(roi) for roi in rois]
        if not rois:
            return {"imageSize": [0, 0], "rois": []}
        size = np.asarray(rois[0]["imagesize"], dtype=float).ravel()
        codes = np.asarray(classes, dtype=float).ravel() if classes is not None and np.size(classes) else np.zeros(0)
        if codes.size != len(rois):
            codes = np.zeros(len(rois))   # as dev: a classification of the wrong size is reset
        out = []
        for roi, code in zip(rois, codes):
            shape = str(roi["shape"])
            coordinates = np.asarray(roi["coordinates"], dtype=np.float64)
            if shape == "Circle":
                pixels = _circle_pixels(*coordinates.ravel()[:3])
            elif shape == "Polygon":
                points = coordinates.reshape(-1, 2)
                pixels = [(r, c) for r in range(int(size[0])) for c in range(int(size[1]))
                          if in_polygon(points[:, 0], points[:, 1], c + 1, r + 1)]
            else:   # Mask, IMask, Donut: 1-based x, y of each pixel
                points = coordinates.reshape(-1, coordinates.shape[-1] if coordinates.ndim == 2 else 2)[:, :2]
                weights = np.asarray(roi.get("pixelweights", []), dtype=np.float64).ravel()
                if shape == "IMask" and weights.size == len(points):
                    points = points[weights > 0]
                pixels = [(_round_away(y) - 1, _round_away(x) - 1) for x, y in points]
            out.append((pixels, DEV_CLASSIFICATIONS.get(int(code))))
        return roi_document(size, out)

    def write(self, path, data):
        import uuid
        from scipy.io import savemat
        height, width = (int(v) for v in data.get("imageSize", [0, 0]))
        rois = data.get("rois", [])
        records = np.empty((1, len(rois)), dtype=[(f, "O") for f in DEV_ROI_FIELDS])
        codes = np.zeros((len(rois), 1))
        for k, roi in enumerate(rois):
            pixels = np.asarray(roi["pixels"], dtype=np.float64).reshape(-1, 2)
            coordinates = np.stack([pixels[:, 1] + 1, pixels[:, 0] + 1], axis=1)   # 1-based x, y
            boundary = np.empty((1, 1), dtype=object)
            boundary[0, 0] = np.array([[np.nan, np.nan]])
            records[0, k] = (str(uuid.uuid4()), "Mask", coordinates, np.zeros((0, 0)), np.array([height, width], dtype=float),
                             boundary, float(len(pixels)), coordinates.mean(axis=0) if len(pixels) else np.zeros((0, 0)),
                             np.empty((0, 0), dtype=object), np.zeros((0, 0)), "", "na", "", np.empty((0, 1), dtype=object), np.zeros((0, 0)))
            codes[k, 0] = {"accepted": 1, "rejected": 2}.get(roi.get("classification"), 0)
        savemat(str(path), {"roiArray": records, "roiClassification": codes, "roiImages": np.zeros((0, 0)), "roiStats": np.zeros((0, 0))})


def _plain(value):
    """A struct scipy left as a mat_struct (one inside a cell) as a dict."""
    if hasattr(value, "_fieldnames"):
        return {name: getattr(value, name) for name in value._fieldnames}
    return value


def _groups(rois):
    """Whether dev's roiArray is a cell of ROI arrays, one per plane and channel, rather than one array."""
    if isinstance(rois, dict) or rois is None:
        return False
    items = list(rois) if isinstance(rois, (list, np.ndarray)) else []
    return bool(items) and not isinstance(items[0], dict) and not hasattr(items[0], "_fieldnames")


def _circle_pixels(x, y, r):
    """dev's RoI.getPixelIdxList for a circle: a local disk offset by the centre's fraction, placed at the centre."""
    steps = [-r + k for k in range(int(np.floor(2 * r + 1e-9)) + 1)]
    a = [s - (x % 1) for s in steps]   # meshgrid's x: along columns
    b = [s - (y % 1) for s in steps]   # meshgrid's y: along rows
    local = [(i + 1, j + 1) for j in range(len(a)) for i in range(len(b)) if a[j] ** 2 + b[i] ** 2 < r ** 2]  # find(): column-major
    if not local:
        return []
    x0 = np.mean([i for i, _ in local])
    y0 = np.mean([j for _, j in local])
    # dev names the row index X and the column index Y, and indexes the image with (Y, X)
    return [(_round_away(j + y - y0) - 1, _round_away(i + x - x0) - 1) for i, j in local]


class Suite2pRois:
    """suite2p's Fall.mat: stat (each cell's 0-based ypix and xpix), iscell (what suite2p's classifier keeps)
    and ops (Ly, Lx). Cells the classifier leaves out are classified rejected."""

    extensions = [".mat"]

    def read(self, path):
        data = _mat(path)
        if "stat" not in data or "ops" not in data:
            raise NansenError("invalid-data", f"{path} is not suite2p's Fall.mat (no stat or ops)")
        stat = data["stat"]
        stat = [stat] if isinstance(stat, dict) else list(stat)
        iscell = np.atleast_2d(np.asarray(data.get("iscell", np.ones((len(stat), 1))), dtype=float))
        ops = data["ops"]
        rois = []
        for k, cell in enumerate(stat):
            ys = np.atleast_1d(np.asarray(cell["ypix"])).ravel()
            xs = np.atleast_1d(np.asarray(cell["xpix"])).ravel()
            kept = iscell[k, 0] if k < iscell.shape[0] else 1
            rois.append((list(zip(ys, xs)), None if kept else "rejected"))
        return roi_document([ops["Ly"], ops["Lx"]], rois)

    def write(self, path, data):
        raise NansenError("invalid-params", "suite2p's files are written by suite2p; ROIs are saved as JSON")


class CaimanRois:
    """CaImAn's HDF5 results: estimates/A (the spatial components, a sparse pixels x components matrix with the
    pixels in Fortran order) and dims. Each component's ROI is the area around its peak, as weights_pixels (needs h5py)."""

    extensions = [".hdf5", ".h5"]

    def read(self, path):
        h5py = _h5py()
        with h5py.File(str(path), "r") as f:
            if "estimates/A/data" not in f or "dims" not in f:
                raise NansenError("invalid-data", f"{path} has no estimates/A and dims of CaImAn's results")
            group = f["estimates/A"]
            data, indices, indptr = group["data"][()], group["indices"][()], group["indptr"][()]
            dims = [int(d) for d in np.ravel(f["dims"][()])[:2]]
        rois = []
        for k in range(len(indptr) - 1):
            image = np.zeros(dims[0] * dims[1])
            image[indices[indptr[k]:indptr[k + 1]]] = data[indptr[k]:indptr[k + 1]]
            rois.append((weights_pixels(image.reshape(dims, order="F")), None))
        return roi_document(dims, rois)

    def write(self, path, data):
        raise NansenError("invalid-params", "CaImAn's files are written by CaImAn; ROIs are saved as JSON")


class ExtractRois:
    """EXTRACT's output saved in a .mat file: output.spatial_weights (height x width x cells). Each cell's ROI is
    the area around its peak, as weights_pixels."""

    extensions = [".mat"]

    def read(self, path):
        data = _mat(path)
        output = data.get("output")
        if not isinstance(output, dict) or "spatial_weights" not in output:
            raise NansenError("invalid-data", f"{path} has no output.spatial_weights of EXTRACT")
        weights = np.asarray(output["spatial_weights"], dtype=np.float64)
        if weights.ndim == 2:
            weights = weights[:, :, None]
        return roi_document(weights.shape[:2], [(weights_pixels(weights[:, :, k]), None) for k in range(weights.shape[2])])

    def write(self, path, data):
        raise NansenError("invalid-params", "EXTRACT's files are written by EXTRACT; ROIs are saved as JSON")


# --- more stacks --------------------------------------------------------------------------------------------------------

class PrairieTSeries:
    """A Bruker (Prairie View) T-series: the XML file, which lists a TIFF file (and page) per frame and channel.
    Reads height x width x frames, or height x width x channels x frames with more than one channel, a frame at
    a time from its files."""

    extensions = [".xml"]

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import join, natural_order
        return join([self._open_one(Path(p)) for p in natural_order(paths)])

    def _open_one(self, path):
        from nansen.stacks import Stack
        text = path.read_text(encoding="utf-8", errors="replace")
        frames = []
        for body in re.findall(r"<Frame\b[^>]*>(.*?)</Frame>", text, flags=re.S):
            files = {}
            for tag in re.findall(r"<File\b[^>]*>", body):
                attributes = dict(re.findall(r'(\w+)="([^"]*)"', tag))
                if "channel" in attributes and "filename" in attributes:
                    files[int(attributes["channel"])] = (attributes["filename"], int(attributes.get("page", "1")))
            if files:
                frames.append(files)
        if not frames:
            raise NansenError("invalid-data", f"{path} lists no frames (not a Prairie View T-series)")
        channels = sorted(frames[0])
        if any(sorted(f) != channels for f in frames):
            raise NansenError("invalid-data", f"{path}: the frames do not all have channels {channels}")
        tifffile = _tifffile()

        def page(name, number):
            with tifffile.TiffFile(str(path.parent / name)) as tif:
                return tif.pages[number - 1].asarray()

        first = page(*frames[0][channels[0]])

        def read(start, stop):
            out = np.empty(first.shape + (len(channels), stop - start), dtype=first.dtype)
            for t in range(start, stop):
                for c, channel in enumerate(channels):
                    out[:, :, c, t - start] = page(*frames[t][channel])
            return out[:, :, 0, :] if len(channels) == 1 else out

        shape = first.shape + ((len(channels),) if len(channels) > 1 else ()) + (len(frames),)
        return Stack(shape, first.dtype, read)

    def write(self, path, data):
        raise NansenError("invalid-params", "Prairie View files are written by the microscope; save a stack with npy or ophys.tiff_stack")


class Hdf5Stack:
    """A stack in an HDF5 file: the dataset data (or mov, or the only one of 3 dimensions), frames x height x width as
    h5py shows it (C order), as suite2p, CaImAn and DeepInterpolation write them. Read as height x width x frames, a
    chunk at a time; written as data (needs h5py)."""

    extensions = [".h5", ".hdf5"]

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import join, natural_order
        return join([self._open_one(Path(p)) for p in natural_order(paths)])

    def _open_one(self, path):
        from nansen.stacks import Stack
        h5py = _h5py()
        with h5py.File(str(path), "r") as f:
            name = _dataset(f, path)
            frames, height, width = f[name].shape
            dtype = f[name].dtype

        def read(start, stop):
            with h5py.File(str(path), "r") as f:
                return np.moveaxis(f[name][start:stop], 0, 2)

        return Stack((height, width, frames), dtype, read)

    def write(self, path, data):
        h5py = _h5py()
        data = np.asarray(data)
        if data.ndim == 2:
            data = data[:, :, None]
        if data.ndim != 3:
            raise NansenError("invalid-params", "an HDF5 stack is height x width x frames")
        with h5py.File(str(path), "w") as f:
            f["data"] = np.moveaxis(data, 2, 0)


def _dataset(f, path):
    for name in ("data", "mov", "mov_data"):
        if name in f and len(f[name].shape) == 3:
            return name
    found = []
    f.visititems(lambda name, item: found.append(name) if hasattr(item, "shape") and len(item.shape) == 3 else None)
    if len(found) != 1:
        raise NansenError("invalid-data", f"{path} has no dataset data, and {len(found)} of 3 dimensions")
    return found[0]


def _h5py():
    try:
        import h5py
    except ImportError:
        raise NansenError("adapter-unavailable", 'HDF5 files need h5py: pip install "nansen-core[hdf5]"') from None
    return h5py
