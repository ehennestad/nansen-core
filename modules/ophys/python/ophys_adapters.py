"""File adapters of the ophys module: SciScan raw recordings and TIFF stacks, as height x width x frames.

The stacks of the microscopes' files carry what the files tell about the recording as their metadata
(nansen.stacks.Stack): frameRate, pixelSize and zStep, as dev's getScanParameters reads them.
"""

import math
import pickle
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


def stack_metadata(frame_rate=None, pixel_size=None, z_step=None, zoom=None):
    """A stack's metadata: frameRate, pixelSize ([x, y]), zStep and zoomFactor (the microscope's), those given as positive
    finite numbers, rounded to 6 decimals (floor(v * 1e6 + 0.5) / 1e6, as MATLAB's ophys.internal.stackMetadata)."""
    usable = lambda v: v is not None and math.isfinite(v) and v > 0
    rounded = lambda v: math.floor(v * 1e6 + 0.5) / 1e6
    out = {}
    if usable(frame_rate):
        out["frameRate"] = rounded(frame_rate)
    if pixel_size is not None and all(usable(v) for v in pixel_size):
        out["pixelSize"] = [rounded(v) for v in pixel_size]
    if usable(z_step):
        out["zStep"] = rounded(z_step)
    if usable(zoom):
        out["zoomFactor"] = rounded(zoom)
    return out


def _number(text):
    """A number in a file's text (a decimal comma too), or None."""
    try:
        return float(str(text).replace(",", "."))
    except ValueError:
        return None


def sciscan_metadata(values, width, height):
    """frames.p.sec; the pixel size from x.fov and y.fov (in m) over x.pixels and y.pixels; z.spacing for a z-stack
    (experiment.type XYTZ); ZOOM, as dev's SciScan stack reads them."""
    number = lambda name: _number(values[name]) if name in values else None
    fov = [number("x.fov"), number("y.fov")]
    size = [abs(fov[0]) * 1e6 / width, abs(fov[1]) * 1e6 / height] if None not in fov else None
    spacing = number("z.spacing") if values.get("experiment.type") == "XYTZ" else None
    return stack_metadata(number("frames.p.sec"), size, abs(spacing) if spacing is not None else None, number("ZOOM"))


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

    def reopen(self, path, shape, dtype):
        """A writer that goes on writing into a stack create began (nansen.progress): None unless its .ini gives this
        size and class. A file cut short (by MATLAB's writer, which writes frames in order) is filled out with zeros;
        frames_on_disk is how many frames it held."""
        from nansen.stacks import StackWriter
        shape, dtype = tuple(int(n) for n in shape), np.dtype(dtype)
        found = self.info(path)
        if found is None or tuple(found[0]) != shape or found[1] != self._disk(dtype):
            return None
        frame_bytes = self._disk(dtype).itemsize * int(np.prod(shape[:-1]))
        size = Path(path).stat().st_size
        if size < frame_bytes * shape[-1]:
            with open(path, "r+b") as f:
                f.truncate(frame_bytes * shape[-1])
        writer = StackWriter(shape, dtype, target=np.memmap(path, dtype=self._disk(dtype), mode="r+", shape=shape, order="F"))
        writer.frames_on_disk = min(shape[-1], size // frame_bytes) if frame_bytes else shape[-1]
        return writer

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
    of frames at a time with imageio and its ffmpeg (the video extra); read only. The frame rate is the video's fps."""

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
                fps = reader.get_meta_data().get("fps")
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

            parts.append(Stack((height, width, count) if gray else (height, width, 3, count), np.uint8, frames, stack_metadata(fps)))
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
        return Stack(shape, native, read, sciscan_metadata(values, width, height))

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
    """A multi-page TIFF file, as height x width x frames (needs tifffile).

    Pages of several samples (RGB, or grayscale with extra samples; contiguous or planar) are channels: height x width
    x samples x frames, as dev's TiffMultiPart reads them (its multisample channel mode). A recording split into a file
    series per channel (dev's TiffMultiPartMultiChannel: rec_ch1_part_001.tif, rec_ch2_part_001.tif, ...) is height x
    width x channels x frames: when every file's name has a channel number (tiff_channel) and there are at least two,
    the files of each channel are its frames, joined in natural order, and the channels come in the order of their
    numbers. Otherwise every file is a part of one recording, joined along the frames in natural order.
    """

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        """The pages of the files, in natural order, as one stack read page by page; files per channel as channels."""
        from nansen.stacks import Stack, natural_order
        paths = [str(p) for p in natural_order(paths)]
        groups = tiff_channel_groups(paths)
        if groups is None:
            return _tiff_series(paths, samples=True)
        channels = [_tiff_series(group, samples=False) for group in groups]
        first = channels[0]
        if any(c.shape != first.shape or c.dtype != first.dtype for c in channels):
            raise NansenError("invalid-data", "the channels of the recording differ in size, frames or type: "
                                              + ", ".join(f"{c.shape} {c.dtype}" for c in channels))
        height, width, frames = first.shape
        return Stack((height, width, len(channels), frames), first.dtype,
                     lambda start, stop: np.stack([c.frames(start, stop) for c in channels], axis=2))

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
    TSM stack does. The frame rate is 1 / EXPOSURE (seconds per frame), when the header has it. Read a chunk at a time;
    read only."""

    extensions = [".tsm"]

    @staticmethod
    def header(path):
        """(columns, rows, frames, offset of the data, EXPOSURE or None) from the header cards."""
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
        return columns, rows, frames, offset, _number(values["EXPOSURE"]) if "EXPOSURE" in values else None

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import Stack, join, natural_order
        parts = []
        for path in natural_order(paths):
            columns, rows, frames, offset, exposure = self.header(path)
            needed = offset + (frames + 1) * rows * columns * 2
            if Path(path).stat().st_size < needed:
                raise NansenError("invalid-data", f"{path} is {Path(path).stat().st_size} bytes; {frames} frames and a dark frame of {rows} x {columns} need {needed}")
            data = np.memmap(path, dtype="<i2", mode="r", offset=offset, shape=(frames + 1, rows, columns))
            dark = np.asarray(data[frames], dtype=np.int32)

            def read(start, stop, data=data, dark=dark):
                chunk = np.asarray(data[start:stop], dtype=np.int32) - dark
                return np.moveaxis(np.clip(chunk, -32768, 32767).astype(np.int16), 0, 2)

            parts.append(Stack((rows, columns, frames), np.int16, read, stack_metadata(1 / exposure if exposure else None)))
        return join(parts)

    def write(self, path, data):
        raise NansenError("invalid-params", "TSM files are written by the camera; save stacks as TIFF")


class NorpixSeq:
    """A Norpix StreamPix sequence (.seq), as dev's Sequence stack: a 1024-byte header (0xFEED, then width, height,
    bit depth, image size, image format and frame count as uint32 from byte 548, and the frame rate as a double at 584),
    then the frames, each trueImageSize bytes apart (the image, its timestamp and padding). Raw images only (image
    format 100, grayscale of 8 or 16 bits, or 200, BGR of 8 bits): height x width x frames, or height x width x 3 x
    frames in RGB order. Read a chunk at a time; read only."""

    extensions = [".seq"]

    @staticmethod
    def header(path):
        """(width, height, bit depth, image bytes, image format, frames, true image size, frame rate) of the header."""
        with open(path, "rb") as f:
            head = f.read(1024)
        if len(head) < 1024 or int.from_bytes(head[:4], "little") != 0xFEED:
            raise NansenError("invalid-data", f"{path} is not a Norpix sequence (no 0xFEED header)")
        values = np.frombuffer(head[548:584], dtype="<u4")
        rate = float(np.frombuffer(head[584:592], dtype="<f8")[0])
        width, height, depth, _, size, kind, frames, _, true_size = (int(v) for v in values)
        return width, height, depth, size, kind, frames, true_size, rate

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import Stack, join, natural_order
        parts = []
        for path in natural_order(paths):
            width, height, depth, size, kind, frames, true_size, rate = self.header(path)
            if (kind, depth) not in ((100, 8), (100, 16), (200, 24)):
                raise NansenError("invalid-data", f"{path} has image format {kind} of {depth} bits; raw grayscale (100) of 8 or "
                                                  "16 bits and raw BGR (200) of 24 are read")
            colours = 3 if kind == 200 else 1
            dtype = np.dtype("<u2") if depth == 16 else np.dtype(np.uint8)
            if size != width * height * colours * dtype.itemsize or true_size < size:
                raise NansenError("invalid-data", f"{path}: an image of {size} bytes in {true_size} does not fit {height} x {width}")
            available = (Path(path).stat().st_size - 1024 + true_size - size) // true_size
            frames = min(frames, available)   # an incomplete last frame is left out
            mapped = np.memmap(path, dtype=np.uint8, mode="r", offset=1024) if frames else None

            def read(start, stop, mapped=mapped, size=size, true_size=true_size, dtype=dtype, height=height, width=width,
                     colours=colours):
                raw = b"".join(mapped[t * true_size:t * true_size + size].tobytes() for t in range(start, stop))
                images = np.frombuffer(raw, dtype=dtype).reshape(stop - start, height, width, colours)
                if colours == 3:
                    return np.ascontiguousarray(images[..., ::-1].transpose(1, 2, 3, 0))   # BGR to RGB
                return np.ascontiguousarray(images[..., 0].transpose(1, 2, 0)).astype(dtype.newbyteorder("="))

            shape = (height, width, 3, frames) if colours == 3 else (height, width, frames)
            parts.append(Stack(shape, dtype.newbyteorder("="), read, stack_metadata(rate)))
        return join(parts)

    def write(self, path, data):
        raise NansenError("invalid-params", "Norpix sequences are written by StreamPix; save stacks as TIFF")


class ThorLabsTiffs:
    """A ThorImage recording: a TIFF file per frame and channel, named ChanA_001_001_001_0001.tif and so on, as dev's
    ThorLabsTiffs reads them. The files of each channel letter are its frames, in natural order; with more than
    one channel the stack is height x width x channels x frames, channels in letter order. Read a chunk at a time. The
    frame rate and pixel size are the LSM element's frameRate and pixelSizeUM in the Experiment.xml beside the files."""

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
        metadata = thorlabs_metadata(Path(paths[0]).parent / "Experiment.xml")
        if len(channels) == 1:
            channels[0].metadata = metadata
            return channels[0]
        first = channels[0]
        if any(c.shape != first.shape or c.dtype != first.dtype for c in channels):
            raise NansenError("invalid-data", "the channels of the recording differ in size, frames or type")
        height, width, frames = first.shape
        return Stack((height, width, len(channels), frames), first.dtype,
                     lambda start, stop: np.stack([c.frames(start, stop) for c in channels], axis=2), metadata)

    def write(self, path, data):
        raise NansenError("invalid-params", "ThorImage files are written by ThorImage; save stacks as TIFF")


class ImageFiles:
    """A sequence of image files (PNG, JPEG, BMP, ...), one frame per file in natural order, as dev's virtual Image
    stack: matched by a file pattern with cardinality many. Grayscale images are height x width x frames, colour ones
    height x width x 3 x frames (RGB; an alpha channel is left out). Read a chunk at a time; read only."""

    extensions = [".png", ".jpg", ".jpeg", ".bmp", ".gif"]

    def read(self, path):
        return np.ascontiguousarray(np.asarray(self.open([path])))

    def open(self, paths):
        from nansen.stacks import Stack, natural_order
        paths = [Path(p) for p in natural_order(paths)]
        read_image = _image_reader()
        first = read_image(paths[0])

        def read(start, stop):
            frames = [first if t == 0 else read_image(paths[t]) for t in range(start, stop)]
            for t, frame in zip(range(start, stop), frames):
                if frame.shape != first.shape or frame.dtype != first.dtype:
                    raise NansenError("invalid-data", f"{paths[t].name} differs in size or type from {paths[0].name}")
            return np.stack(frames, axis=-1)

        return Stack(first.shape + (len(paths),), first.dtype, read)

    def write(self, path, data):
        raise NansenError("invalid-params", "image files are read as a stack; save stacks as TIFF")


def _image_reader():
    """A function that reads an image file as height x width (grayscale) or height x width x 3 (RGB)."""
    try:
        import imageio.v2 as iio
    except ImportError:
        raise NansenError("adapter-unavailable", 'image files need imageio: pip install "nansen-core[video]"') from None

    def read(path):
        image = np.asarray(iio.imread(path))
        if image.ndim == 3:
            image = image[:, :, :3]   # an alpha channel left out
            if image.shape[2] == 1:
                image = image[:, :, 0]
        return image
    return read


def thorlabs_metadata(path):
    """frameRate and pixelSizeUM of the LSM element of a ThorImage Experiment.xml, as dev's getScanParameters; {} without one."""
    if not path.is_file():
        return {}
    tag = re.search(r"<LSM\s[^>]*>", path.read_text(encoding="utf-8", errors="replace"))
    attributes = dict(re.findall(r'(\w+)="([^"]*)"', tag.group())) if tag else {}
    number = lambda name: _number(attributes[name]) if name in attributes else None
    size = number("pixelSizeUM")
    return stack_metadata(number("frameRate"), [size, size] if size is not None else None)


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
    Its metadata is read from the same text (scanimage_metadata).
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
        return Stack(probe.shape[:-1] + (volumes,), dtype, read, scanimage_metadata(text, artist, planes, mosaic))

    def write(self, path, data):
        raise NansenError("invalid-params", "ScanImage files are written by ScanImage; save a stack with npy or ophys.tiff_stack")


def si_numbers(text, name):
    """The numbers of the SI.<name> = value line of ScanImage metadata (true is 1, false 0); [] if there is none."""
    match = re.search(r"(?:^|\n)\s*(?:scanimage\.)?SI\." + re.escape(name) + r"\s*=\s*([^\n]*)", text)
    if not match:
        return []
    value = match.group(1).replace("true", "1").replace("false", "0")
    return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", value)]


def scanimage_metadata(text, artist, planes, mosaic):
    """A ScanImage recording's metadata. frameRate: SI.hRoiManager.scanVolumeRate, else scanFrameRate when it has one
    plane. zStep, with more than one plane: SI.hStackManager.actualStackZStepSize, else stackZStepSize. pixelSize: the
    extent of the corners SI.hRoiManager.imagingFovUm (or imagingFovDeg times SI.objectiveResolution, µm per degree)
    over pixelsPerLine and linesPerFrame; for a multi-ROI recording, the first ROI's scanfield sizeXY (degrees) times
    SI.objectiveResolution over its pixelResolutionXY."""
    import json

    first = lambda name: (si_numbers(text, name) or [None])[0]
    rate = first("hRoiManager.scanVolumeRate")
    if rate is None and planes == 1:
        rate = first("hRoiManager.scanFrameRate")
    step = None
    if planes > 1:
        step = first("hStackManager.actualStackZStepSize")
        if step is None:
            step = first("hStackManager.stackZStepSize")
    resolution = first("objectiveResolution")
    size = None
    if mosaic:
        rois = json.loads(artist)["RoiGroups"]["imagingRoiGroup"]["rois"]
        roi = rois[0] if isinstance(rois, list) else rois
        field = roi["scanfields"][0] if isinstance(roi["scanfields"], list) else roi["scanfields"]
        if resolution is not None and "sizeXY" in field:
            size = [float(field["sizeXY"][k]) * resolution / float(field["pixelResolutionXY"][k]) for k in (0, 1)]
    else:
        corners = si_numbers(text, "hRoiManager.imagingFovUm")
        if not corners and resolution is not None:
            corners = [v * resolution for v in si_numbers(text, "hRoiManager.imagingFovDeg")]
        pixels, lines = first("hRoiManager.pixelsPerLine"), first("hRoiManager.linesPerFrame")
        if len(corners) >= 4 and len(corners) % 2 == 0 and pixels and lines:
            xs, ys = corners[0::2], corners[1::2]
            size = [(max(xs) - min(xs)) / pixels, (max(ys) - min(ys)) / lines]
    return stack_metadata(rate, size, abs(step) if step is not None else None)


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


# A channel number in a file name: ch1, chan1, channel1 (any case, _ or - before the number allowed: ch_1), not after a
# letter or digit; else C1 followed by -, _ or . (as ImageJ names a stack's channels: C1-rec.tif). The first match counts.
# MATLAB's ophys.TiffStack.channelNumber uses the same patterns.
TIFF_CHANNEL_NAMES = (re.compile(r"(?<![A-Za-z0-9])(?:ch|chan|channel)[_-]?(\d+)(?!\d)", re.IGNORECASE),
                      re.compile(r"(?<![A-Za-z0-9])C(\d+)(?=[-_.])"))


def tiff_channel(name):
    """The channel number in a TIFF file's name (TIFF_CHANNEL_NAMES), or None."""
    for pattern in TIFF_CHANNEL_NAMES:
        match = pattern.search(name)
        if match:
            return int(match.group(1))
    return None


def tiff_channel_groups(paths):
    """The paths of each channel, in the order of the channel numbers, when there are several files, each with a
    channel number in its name, and at least two channels; None otherwise (one recording in parts)."""
    if len(paths) < 2:
        return None
    numbers = [tiff_channel(Path(p).name) for p in paths]
    if any(n is None for n in numbers) or len(set(numbers)) < 2:
        return None
    return [[p for p, n in zip(paths, numbers) if n == channel] for channel in sorted(set(numbers))]


def _tiff_series(paths, samples):
    """The pages of TIFF files one after another, as height x width x frames, or height x width x samples x frames
    for pages of several samples (refused unless samples)."""
    from nansen.stacks import Stack, pages
    with _tifffile().TiffFile(paths[0]) as tif:
        frame_shape, dtype = _page_shape(tif.pages[0]), tif.pages[0].dtype
    if len(frame_shape) != 2 and not (samples and len(frame_shape) == 3):
        raise NansenError("invalid-data", f"{paths[0]} holds pages of {frame_shape}; a TIFF stack of grayscale frames"
                                          + (", or of frames of several samples," if samples else " in a file per channel") + " is read")
    count, read_pages = pages(paths, _page_info, _read_pages, frame_shape, dtype)
    return Stack(frame_shape + (count,), dtype, lambda start, stop: np.moveaxis(read_pages(start, stop), 0, -1))


def _page_shape(page):
    """A TIFF page's shape, its samples last (height x width x samples) also when they are stored planar."""
    shape = tuple(page.shape)
    return shape[1:] + shape[:1] if len(shape) == 3 and page.axes.startswith("S") else shape


def _page_array(page):
    data = page.asarray()
    return np.moveaxis(data, 0, -1) if data.ndim == 3 and page.axes.startswith("S") else data


def _page_info(path):
    """A TIFF file's page count, and its first page's shape (samples last) and type."""
    with _tifffile().TiffFile(str(path)) as tif:
        return len(tif.pages), _page_shape(tif.pages[0]), tif.pages[0].dtype


def _read_pages(path, start, stop):
    with _tifffile().TiffFile(str(path)) as tif:
        return np.stack([_page_array(tif.pages[i]) for i in range(start, stop)], axis=0)


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

def roi_document(image_size, rois, places=None):
    """The ROI document of a list of (pixels, classification) in file order; places, when given, is each ROI's
    (plane, channel), from 1."""
    height, width = int(image_size[0]), int(image_size[1])
    out = []
    for number, entry in enumerate(rois, start=1):
        pixels, classification = entry[0], entry[1]
        extras = entry[2] if len(entry) > 2 else {}
        kept = sorted({(int(r), int(c)) for r, c in pixels if 0 <= r < height and 0 <= c < width})
        rows = np.array([p[0] for p in kept], dtype=np.float64)
        columns = np.array([p[1] for p in kept], dtype=np.float64)
        roi = {"id": number, "area": len(kept),
               "center": [_round2(rows.mean()) if kept else None, _round2(columns.mean()) if kept else None],
               "pixels": [[r, c] for r, c in kept]}
        if classification:
            roi["classification"] = classification
        for name in ("uid", "cellType", "tags"):   # dev's RoI identity, cell type and tags, when it has them
            if extras.get(name):
                roi[name] = extras[name]
        if places is not None:
            roi["plane"], roi["channel"] = int(places[number - 1][0]), int(places[number - 1][1])
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


DEV_CLASSIFICATIONS = {1: "accepted", 2: "rejected", 3: "unresolved"}   # dev's roiClassification: 0 unclassified
DEV_ROI_FIELDS = ["uid", "shape", "coordinates", "pixelweights", "imagesize", "boundary", "area", "center", "connectedrois",
                  "group", "celltype", "structure", "layer", "tags", "enhancedImage"]


class NansenRoiArray:
    """dev's ROI file (.mat): a struct array roiArray (or RoiArray, roi_arr) of RoI properties, as dev's
    roimanager and RoiGroup adapter save them, with roiClassification beside it (1 accepted, 2 rejected; 0
    unclassified; 3 unresolved). Mask and Donut ROIs are their pixels, given as 1-based
    x (column), y (row); IMask ROIs those of weight above 0; Circle ROIs are x, y and a radius, made into pixels as
    dev's RoI does; Polygon ROIs are the pixels whose centre is inside, by the even-odd rule. A file of several
    planes or channels (dev's RoiGroup: cells of them, planes x channels, with PlaneNumber and ChannelNumber) is read
    whole, each ROI with its plane and channel. Written as dev's RoiGroup adapter writes: Mask ROIs and their
    classification, which dev reads, as cells of planes x channels when the ROIs have places."""

    extensions = [".mat"]

    def read(self, path):
        data = _mat(path)
        name = next((n for n in ("roiArray", "RoiArray", "roi_arr") if n in data), None)
        if name is None:
            raise NansenError("invalid-data", f"{path} has no roiArray")
        rois, classes = data[name], data.get("roiClassification")
        planes, channels = data.get("PlaneNumber"), data.get("ChannelNumber")
        if not _groups(rois):
            size, out = self._group(rois, classes)
            return _dev_links(roi_document(size if size is not None else [0, 0], out), out)
        # dev's RoiGroup of several planes or channels (a cell of ROI arrays, planes x channels): every ROI, with its place
        groups = np.asarray(rois, dtype=object).ravel(order="F") if not isinstance(rois, list) else rois
        class_groups = _cells(classes, len(groups))
        shape = np.shape(rois) if np.ndim(rois) == 2 else (len(groups), 1)
        plane_numbers, channel_numbers = _cells(planes, len(groups)), _cells(channels, len(groups))
        size, out, places = None, [], []
        for k, group in enumerate(groups):
            group_size, group_rois = self._group(group, class_groups[k])
            size = size if size is not None else group_size
            plane = int(np.asarray(plane_numbers[k]).ravel()[0]) if np.size(plane_numbers[k]) else k % shape[0] + 1
            channel = int(np.asarray(channel_numbers[k]).ravel()[0]) if np.size(channel_numbers[k]) else k // shape[0] + 1
            out += group_rois
            places += [(plane, channel)] * len(group_rois)
        return _dev_links(roi_document(size if size is not None else [0, 0], out, places), out)

    @staticmethod
    def _group(rois, classes):
        """One plane's ROIs as (pixels, classification), and their image size (None when there are none)."""
        rois = [rois] if isinstance(rois, dict) or hasattr(rois, "_fieldnames") else list(rois) if rois is not None and np.size(rois) else []
        rois = [_plain(roi) for roi in rois]
        if not rois:
            return None, []
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
            out.append((pixels, DEV_CLASSIFICATIONS.get(int(code)), _dev_extras(roi)))
        return size, out

    def write(self, path, data):
        from scipy.io import savemat
        height, width = (int(v) for v in data.get("imageSize", [0, 0]))
        import uuid
        rois = data.get("rois", [])
        uids = {roi.get("id", k + 1): roi.get("uid") or str(uuid.uuid4()) for k, roi in enumerate(rois)}   # links are by uid
        contents = {"roiImages": np.zeros((0, 0)), "roiStats": np.zeros((0, 0))}
        if not any("plane" in roi or "channel" in roi for roi in rois):
            contents["roiArray"], contents["roiClassification"] = self._records(rois, height, width, uids)
        else:   # dev's RoiGroup: cells of planes x channels
            planes = max(int(roi.get("plane", 1)) for roi in rois)
            channels = max(int(roi.get("channel", 1)) for roi in rois)
            names = ("roiArray", "roiClassification", "PlaneNumber", "ChannelNumber")
            cells = {name: np.empty((planes, channels), dtype=object) for name in names}
            for p in range(planes):
                for c in range(channels):
                    group = [roi for roi in rois if int(roi.get("plane", 1)) == p + 1 and int(roi.get("channel", 1)) == c + 1]
                    cells["roiArray"][p, c], cells["roiClassification"][p, c] = self._records(group, height, width, uids)
                    cells["PlaneNumber"][p, c], cells["ChannelNumber"][p, c] = float(p + 1), float(c + 1)
            contents.update(cells)
        savemat(str(path), contents)

    @staticmethod
    def _records(rois, height, width, uids):
        """dev's roiArray of Mask ROIs and its roiClassification; uids maps every ROI's id to its uid."""
        records = np.empty((1, len(rois)), dtype=[(f, "O") for f in DEV_ROI_FIELDS])
        codes = np.zeros((len(rois), 1))
        for k, roi in enumerate(rois):
            pixels = np.asarray(roi["pixels"], dtype=np.float64).reshape(-1, 2)
            coordinates = np.stack([pixels[:, 1] + 1, pixels[:, 0] + 1], axis=1)   # 1-based x, y
            boundary = np.empty((1, 1), dtype=object)
            boundary[0, 0] = np.array([[np.nan, np.nan]])
            linked = [uids[i] for i in roi.get("links", []) if i in uids]
            connected = np.empty((1, len(linked)) if linked else (0, 0), dtype=object)
            for i, uid in enumerate(linked):
                connected.flat[i] = uid
            tags = np.empty((len(roi.get("tags", [])), 1), dtype=object)
            for i, tag in enumerate(roi.get("tags", [])):
                tags.flat[i] = tag
            records[0, k] = (uids[roi.get("id", k + 1)], "Mask", coordinates, np.zeros((0, 0)), np.array([height, width], dtype=float),
                             boundary, float(len(pixels)), coordinates.mean(axis=0) if len(pixels) else np.zeros((0, 0)),
                             connected, np.zeros((0, 0)), roi.get("cellType", ""), "na", "", tags, np.zeros((0, 0)))
            codes[k, 0] = {"accepted": 1, "rejected": 2, "unresolved": 3}.get(roi.get("classification"), 0)
        return records, codes


def _dev_extras(roi):
    """What a dev RoI says besides its pixels: uid, cell type, tags and the uids it is connected with."""
    text = lambda v: v.decode() if isinstance(v, bytes) else str(v) if isinstance(v, str) else ""
    items = lambda v: [text(x) for x in np.asarray(v, dtype=object).ravel() if text(x)] if v is not None and np.size(v) and not isinstance(v, str) \
        else ([v] if isinstance(v, str) and v else [])
    return {"uid": text(roi.get("uid")), "cellType": text(roi.get("celltype")),
            "tags": items(roi.get("tags")), "connected": items(roi.get("connectedrois"))}


def _dev_links(document, entries):
    """The document with links (ids) for dev's connectedrois (uids) of the ROIs read, in order."""
    ids = {roi.get("uid"): roi["id"] for roi in document["rois"] if roi.get("uid")}
    for roi, entry in zip(document["rois"], entries):
        linked = sorted(ids[u] for u in (entry[2] if len(entry) > 2 else {}).get("connected", []) if u in ids)
        if linked:
            roi["links"] = linked
    return document


def _plain(value):
    """A struct scipy left as a mat_struct (one inside a cell) as a dict."""
    if hasattr(value, "_fieldnames"):
        return {name: getattr(value, name) for name in value._fieldnames}
    return value


def _groups(rois):
    """Whether dev's roiArray is a cell of ROI arrays, one per plane and channel, rather than one array."""
    if isinstance(rois, dict) or rois is None:
        return False
    items = list(np.asarray(rois, dtype=object).ravel()) if isinstance(rois, (list, np.ndarray)) else []
    return any(not isinstance(i, dict) and not hasattr(i, "_fieldnames") for i in items)


def _cells(value, count):
    """The items of a cell of count (column-major), or count empty ones when it does not have that many."""
    if count == 1:
        return [value]
    if value is None or isinstance(value, (str, bytes)):
        return [None] * count
    items = list(np.asarray(value, dtype=object).ravel(order="F")) if np.ndim(value) else [value]
    return items if len(items) == count else [None] * count


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
    """suite2p's cells: stat (each cell's 0-based ypix and xpix), iscell (what suite2p's classifier keeps) and ops
    (Ly, Lx), from its Fall.mat, or from its output folder of .npy files as dev's Suite2p ROI converter collects them
    (stat.npy, with iscell.npy and ops.npy beside it). A folder is a plane's (it has stat.npy), or suite2p's output
    folder (or one holding it, suite2p/) of plane0, plane1, ...: all its planes, each cell with its plane (planeN is
    plane N + 1) and channel 1. stat.npy is a pickled array of dicts, read by read_pickled_npy, which runs nothing in
    it; Ly and Lx are found in ops.npy's bytes, as Suite2pBinary finds them. Cells the classifier leaves out are
    classified rejected."""

    extensions = [".mat", ".npy"]

    def read(self, path):
        path = Path(path)
        if path.is_dir():
            return self._folder(path)
        if path.suffix.lower() == ".npy":
            return roi_document(*self._plane(path))
        data = _mat(path)
        if "stat" not in data or "ops" not in data:
            raise NansenError("invalid-data", f"{path} is not suite2p's Fall.mat (no stat or ops)")
        stat = data["stat"]
        stat = [stat] if isinstance(stat, dict) else list(stat)
        ops = data["ops"]
        return roi_document([ops["Ly"], ops["Lx"]], self._cells(stat, data.get("iscell")))

    @staticmethod
    def _cells(stat, iscell):
        """Each cell's (pixels, classification): rejected where iscell's first column is 0."""
        iscell = np.atleast_2d(np.asarray(iscell if iscell is not None else np.ones((len(stat), 1)), dtype=float))
        rois = []
        for k, cell in enumerate(stat):
            if not isinstance(cell, dict) or "ypix" not in cell or "xpix" not in cell:
                raise NansenError("invalid-data", f"suite2p's stat has no ypix and xpix for cell {k + 1}")
            ys = np.atleast_1d(np.asarray(cell["ypix"])).ravel()
            xs = np.atleast_1d(np.asarray(cell["xpix"])).ravel()
            kept = iscell[k, 0] if k < iscell.shape[0] else 1
            rois.append((list(zip(ys, xs)), None if kept else "rejected"))
        return rois

    @classmethod
    def _plane(cls, path):
        """A plane's stat.npy, with the iscell.npy (if any) and ops.npy beside it: (image size, cells)."""
        path = Path(path)
        ops = path.with_name("ops.npy")
        if not ops.is_file():
            raise NansenError("invalid-data", f"{path}: there is no ops.npy beside it, which has the image size")
        stat = read_pickled_npy(path)
        if not isinstance(stat, np.ndarray) or stat.dtype != object:
            raise NansenError("invalid-data", f"{path} is not suite2p's stat (an array of each cell's dict)")
        iscell = path.with_name("iscell.npy")
        labels = np.load(iscell, allow_pickle=False) if iscell.is_file() else None
        size = [_pickled_int(ops.read_bytes(), key, ops) for key in ("Ly", "Lx")]
        return size, cls._cells(list(stat.ravel()), labels)

    @classmethod
    def _folder(cls, folder):
        if (folder / "stat.npy").is_file():
            return roi_document(*cls._plane(folder / "stat.npy"))
        if not _plane_folders(folder) and (folder / "suite2p").is_dir():
            folder = folder / "suite2p"
        planes = _plane_folders(folder)
        if not planes:
            raise NansenError("invalid-data", f"{folder} has no stat.npy, nor suite2p's plane folders with one")
        size, rois, places = None, [], []
        for number, plane in planes:
            plane_size, cells = cls._plane(plane / "stat.npy")
            size = size if size is not None else plane_size
            rois += cells
            places += [(number + 1, 1)] * len(cells)
        return roi_document(size, rois, places)

    def write(self, path, data):
        raise NansenError("invalid-params", "suite2p's files are written by suite2p; ROIs are saved as JSON")


def _plane_folders(folder):
    """suite2p's plane folders (planeN) with a stat.npy in a folder, as (N, path) in the order of N."""
    found = []
    for path in folder.iterdir():
        match = re.fullmatch(r"plane(\d+)", path.name)
        if match and path.is_dir() and (path / "stat.npy").is_file():
            found.append((int(match.group(1)), path))
    return sorted(found)


def read_pickled_npy(path):
    """The value of a .npy file, of objects too (NumPy's allow_pickle), as suite2p's stat.npy: an array of objects is
    unpickled with only NumPy's array, dtype and scalar classes (and _codecs.encode, which pickle protocol 2 uses for
    bytes, and NumPy's _frombuffer, which protocol 5 uses for arrays), so a file cannot run code; any other class read
    is made an empty placeholder. MATLAB's ophys.internal.readPickledNpy reads the same values of what suite2p's files
    hold (dicts of NumPy arrays and scalars, numbers, text and lists)."""
    import ast
    with open(path, "rb") as f:
        if f.read(6) != b"\x93NUMPY":
            raise NansenError("invalid-data", f"{path} is not a .npy file")
        major = f.read(2)[0]
        length = int.from_bytes(f.read(2 if major == 1 else 4), "little")
        try:
            header = ast.literal_eval(f.read(length).decode("latin1"))
            descr = header["descr"]
        except (ValueError, SyntaxError, KeyError, TypeError):
            raise NansenError("invalid-data", f"{path} has a .npy header this reader does not understand") from None
        if descr not in ("|O", "O"):
            f.seek(0)
            return np.load(f, allow_pickle=False)
        try:
            return _NumpyUnpickler(f, encoding="latin1").load()
        except NansenError:
            raise
        except Exception as error:   # a cut-off or malformed pickle
            raise NansenError("invalid-data", f"{path}: its objects cannot be read ({type(error).__name__}: {error})") from None


class _Opaque:
    """What a pickled object of a class read_pickled_npy does not allow becomes: nothing of it is run or kept."""

    def __init__(self, *args, **kwargs):
        pass

    def __setstate__(self, state):
        pass


def _numpy_class(module, name):
    """The NumPy and codecs callables a pickled NumPy array needs, else None."""
    import codecs
    core = getattr(np, "_core", None) or np.core
    if module in ("numpy._core.multiarray", "numpy.core.multiarray") and name in ("_reconstruct", "scalar"):
        return getattr(core.multiarray, name)
    if module in ("numpy._core.numeric", "numpy.core.numeric") and name == "_frombuffer":   # protocol 5's arrays
        return core.numeric._frombuffer
    if module == "numpy" and name in ("ndarray", "dtype"):
        return getattr(np, name)
    if (module, name) == ("_codecs", "encode"):
        return codecs.encode
    return None


class _NumpyUnpickler(pickle.Unpickler):
    """pickle's reader with only the classes _numpy_class gives; others are _Opaque."""

    def find_class(self, module, name):
        return _numpy_class(module, name) or _Opaque


class VhlabRois:
    """dev's VHLab ROI files (.mat, as the VH lab's analyzetpstack saves them): cellstructs, a struct array whose xi
    and yi are each cell's outline (1-based x, y). Read as dev's dataconvert.roi.vhlab reads them: Polygon ROIs, the
    pixels whose centre is inside by the even-odd rule (as NansenRoiArray's Polygon ROIs), in a 512 x 512 image, the
    size dev gives them (the file has none). Read only."""

    extensions = [".mat"]
    IMAGE_SIZE = (512, 512)

    def read(self, path):
        data = _mat(path)
        cells = data.get("cellstructs")
        if cells is None:
            raise NansenError("invalid-data", f"{path} has no cellstructs of VHLab's ROIs")
        cells = [cells] if isinstance(cells, dict) or hasattr(cells, "_fieldnames") else list(np.asarray(cells, dtype=object).ravel())
        height, width = self.IMAGE_SIZE
        rois = []
        for k, cell in enumerate(_plain(c) for c in cells):
            if not isinstance(cell, dict) or "xi" not in cell or "yi" not in cell:
                raise NansenError("invalid-data", f"{path}: cell {k + 1} of cellstructs has no xi and yi")
            xs = np.asarray(cell["xi"], dtype=np.float64).ravel()
            ys = np.asarray(cell["yi"], dtype=np.float64).ravel()
            rois.append((polygon_pixels(xs, ys, height, width), None))
        return roi_document(self.IMAGE_SIZE, rois)

    def write(self, path, data):
        raise NansenError("invalid-params", "VHLab's ROI files are written by its own tools; ROIs are saved as JSON")


def polygon_pixels(xs, ys, height, width):
    """The 0-based (row, column) pixels of the image whose centre (1-based x column + 1, y row + 1) is inside the
    polygon of vertices (xs, ys), by the even-odd rule; only the pixels around its bounding box are tried. MATLAB's
    ophys.internal.polygonPixels gives the same."""
    if not len(xs):
        return []
    first_row, last_row = max(0, int(np.floor(min(ys))) - 2), min(height - 1, int(np.ceil(max(ys))))
    first_column, last_column = max(0, int(np.floor(min(xs))) - 2), min(width - 1, int(np.ceil(max(xs))))
    return [(r, c) for r in range(first_row, last_row + 1) for c in range(first_column, last_column + 1)
            if in_polygon(xs, ys, c + 1, r + 1)]


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
    a time from its files. The frame rate is 1 / framePeriod and the pixel size micronsPerPixel's XAxis and YAxis,
    of the first PVStateValue of each, as dev's getPrairieMetaData reads them."""

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
        return Stack(shape, first.dtype, read, prairie_metadata(text))

    def write(self, path, data):
        raise NansenError("invalid-params", "Prairie View files are written by the microscope; save a stack with npy or ophys.tiff_stack")


def prairie_metadata(text):
    """frameRate (1 / framePeriod) and pixelSize (micronsPerPixel's XAxis and YAxis) of a Prairie View XML file."""
    attributes = lambda tag: dict(re.findall(r'(\w+)="([^"]*)"', tag))
    tag = re.search(r'<PVStateValue\s[^>]*key="framePeriod"[^>]*>', text)
    period = _number(attributes(tag.group()).get("value", "")) if tag else None
    body = re.search(r'<PVStateValue\s[^>]*key="micronsPerPixel"[^>]*>(.*?)</PVStateValue>', text, flags=re.S)
    axes = {}
    for tag in re.findall(r"<IndexedValue\s[^>]*>", body.group(1) if body else ""):
        found = attributes(tag)
        if "index" in found and "value" in found:
            axes.setdefault(found["index"], _number(found["value"]))
    size = [axes.get("XAxis"), axes.get("YAxis")]
    return stack_metadata(1 / period if period else None, size if None not in size else None)


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
