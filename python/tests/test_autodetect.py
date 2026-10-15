"""dev's roimanager autodetection modes (nansen.autodetect, rois.detect and view.detect mode) and the Mean CLAHE
projection (nansen.frames.mean_clahe), on synthetic cells whose pixels are known."""

import math

import numpy as np
import pytest

from nansen import NansenError
from nansen.autodetect import (active_samples, autodetect_roi, gauss_blur, imresize, makeuint8, prctile,
                               soma_mask_by_threshold)
from nansen.frames import _clip_histogram, clahe, image_frame, mean_clahe
from nansen.stacks import from_array

CENTRE, RADIUS = (20, 18), 4


def recording(frames=60, seed=4, nucleus=5):
    """40 x 40 pixels: a dim, slightly noisy background and a round cell of radius 4 (a darker nucleus within sqrt(5))
    that is active in some frames."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:40, 0:40]
    distance = (yy - CENTRE[0]) ** 2 + (xx - CENTRE[1]) ** 2
    cell = (distance <= RADIUS * RADIUS).astype(float) - 0.5 * (distance <= nucleus)
    activity = np.where(rng.random(frames) < 0.3, 300.0, 40.0)
    data = 100 + rng.normal(0, 2, (40, 40, frames)) + cell[:, :, None] * activity[None, None, :]
    return np.round(data).astype(np.uint16), distance <= RADIUS * RADIUS


@pytest.mark.parametrize("mode", [1, 2, 3, 4, 5])
def test_every_mode_finds_the_cell_around_a_click(mode):
    data, disk = recording()
    found = autodetect_roi(from_array(data), list(CENTRE), RADIUS, mode)
    mask = np.zeros(disk.shape, dtype=bool)
    for y, x in found:
        mask[y, x] = True
    near = np.zeros(disk.shape, dtype=bool)   # the disk, grown by 2 pixels
    for y, x in zip(*np.nonzero(disk)):
        near[max(0, y - 2):y + 3, max(0, x - 2):x + 3] = True
    if mode in (1, 5):   # flufinder's edge detection: the whole cell, its edge at most 2 pixels out
        assert (mask & disk).sum() == disk.sum() and not (mask & ~near).any()
    else:   # thresholding, after a 5 x 5 median filter that rounds the cell's edge off: most of the cell, nothing else
        assert (mask & disk).sum() >= 0.7 * disk.sum() and not (mask & ~disk).any()
    assert found == sorted(found)   # row-major, 0-based


def test_mode_0_is_the_threshold_and_bad_modes_or_points_are_refused():
    data, disk = recording()
    stack = from_array(data)
    from nansen.frames import _mean, detect_roi
    assert autodetect_roi(stack, list(CENTRE), 6, 0) == detect_roi(_mean(stack), list(CENTRE), 6)
    for mode in (6, -1, "1", True, None, 1.5):
        with pytest.raises(NansenError) as error:
            autodetect_roi(stack, list(CENTRE), 4, mode)
        assert error.value.code == "invalid-params"
    with pytest.raises(NansenError):
        autodetect_roi(stack, [40, 0], 4, 1)


def test_a_cell_at_the_edge_and_an_image_of_one_frame():
    data, _ = recording()
    found = autodetect_roi(from_array(data), [0, 0], 4, 1)   # dev's box reaches past the image: 0 there
    assert all(0 <= y < 40 and 0 <= x < 40 for y, x in found)
    image = data.mean(axis=2)[:, :, None]   # a single frame: a flat signal weighs every frame alike
    assert autodetect_roi(from_array(image), list(CENTRE), RADIUS, 1)


def test_the_written_out_toolbox_steps():
    # MATLAB's prctile: the sorted values at 100 (i - 0.5) / n, as NumPy's hazen
    values = np.random.default_rng(1).normal(size=37)
    for p in (0, 5, 20, 50, 99.9, 100):
        assert prctile(values, p) == pytest.approx(np.percentile(values, p, method="hazen"))
    # findActiveSamplePoints: above the 5th percentile, and 2 frames either side
    signal = np.array([5.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    assert list(np.flatnonzero(active_samples(signal))) == [0, 1, 2]
    # bicubic resizing keeps a constant, and a ramp away from the edges
    assert np.allclose(imresize(np.full((5, 3), 7.0), 0, 20, False), 7)
    ramp = imresize(np.arange(10.0), 0, 40, False)
    assert np.allclose(ramp[8:32], (np.arange(8, 32) + 1) / 4 + 0.5 * (1 - 1 / 4) - 1)
    assert np.array_equal(imresize(np.array([0.0, 255.0]), 0, 8, True), np.floor(imresize(np.array([0.0, 255.0]), 0, 8, False) + 0.5).clip(0, 255))
    assert np.allclose(gauss_blur(np.full((4, 6), 3.0), False), 3)
    # makeuint8: from the 0.05th to the 99.95th percentile, rounded
    image = np.arange(100.0).reshape(10, 10)
    assert makeuint8(image).min() == 0 and makeuint8(image).max() == 255
    # thresholding a bright disk on a dark image finds it, its edge rounded off by the 5 x 5 median filter
    yy, xx = np.mgrid[0:21, 0:21]
    disk = (yy - 10) ** 2 + (xx - 10) ** 2 <= 16
    found = soma_mask_by_threshold(np.where(disk, 200.0, 20.0), 8)
    assert not (found & ~disk).any() and np.array_equal(found, (yy - 10) ** 2 + (xx - 10) ** 2 <= 10)


def test_mean_clahe():
    rng = np.random.default_rng(2)
    data = (rng.random((70, 45, 4)) * 1000).astype(np.uint16)
    out = mean_clahe(from_array(data))
    average = data.astype(float).mean(axis=2)
    assert out.shape == (70, 45) and np.array_equal(out, np.round(out))   # rounded as the stack's uint16
    assert out.min() >= average.min() - 0.5 and out.max() <= average.max() + 0.5
    floats = mean_clahe(from_array(data.astype(float)))
    assert not np.array_equal(floats, np.round(floats))
    small = data[:20, :40]   # smaller than 32: the normalised mean, as dev's
    normal = (small.astype(float).mean(axis=2) - small.astype(float).mean(axis=2).min())
    assert np.allclose(mean_clahe(from_array(small)), normal / normal.max())
    flat = np.full((40, 40, 2), 9, dtype=np.uint16)
    assert np.array_equal(mean_clahe(from_array(flat)), np.full((40, 40), 9.0))
    # equalisation spreads a narrow range of values out: the result has more distinct values than 8 bits of a ramp
    ramp = np.tile(np.linspace(0, 1, 64), (64, 1))
    equalised = clahe(ramp)
    assert equalised.shape == (64, 64) and 0 <= equalised.min() and equalised.max() <= 1
    assert image_frame(from_array(data), projection="meanClahe")["frame"] is None


def test_clip_histogram_keeps_every_pixel():
    histogram = [0] * 256
    histogram[3], histogram[10], histogram[200] = 50, 30, 20
    clipped = _clip_histogram(histogram, 2, 256)
    assert sum(clipped) == 100 and max(clipped) <= 2
    assert _clip_histogram([1] * 256, 2, 256) == [1] * 256


def test_rois_detect_and_view_detect_take_a_mode():
    from nansen.api import Api
    from nansen.viewables import Viewables
    data, disk = recording()
    viewables = Viewables()
    viewables.add_stack(data)
    api = Api(viewables=viewables)
    call = lambda **params: api.handle({"id": 1, "method": "view.detect", "params": dict(viewable="v1", **params)})
    default = call(point=list(CENTRE), radius=RADIUS)["result"]["pixels"]
    assert default == autodetect_roi(from_array(data), list(CENTRE), RADIUS, 1)
    assert call(point=list(CENTRE), radius=RADIUS, mode=3)["result"]["pixels"] == autodetect_roi(from_array(data), list(CENTRE), RADIUS, 3)
    assert call(point=list(CENTRE), mode=9)["error"]["code"] == "invalid-params"
    assert len(default) >= math.floor(math.pi * RADIUS ** 2)


def test_the_same_pixels_as_matlab_finds():
    """A recording made the same way in MATLAB's AutodetectTest (no random numbers): both find the same pixels in every
    mode (here a count and the sum of row * 40 + column), through the nucleus's edge too, and the same Mean CLAHE."""
    rows, columns = np.mgrid[1:41, 1:41]
    distance = (rows - 21) ** 2 + (columns - 19) ** 2
    cell = (distance <= 16).astype(float) - 0.5 * (distance <= 5)
    data = np.zeros((40, 40, 60))
    for t in range(1, 61):
        data[:, :, t - 1] = 100 + np.mod(rows * 7 + columns * 3 + t * 5, 5) + cell * (40 + 260 * (t % 3 == 0))
    stack = from_array(data.astype(np.uint16))
    found = [autodetect_roi(stack, [20, 18], 4, mode) for mode in range(6)]
    assert [(len(p), sum(y * 40 + x for y, x in p)) for p in found] == [
        (1, 777), (62, 50800), (37, 30266), (57, 46626), (57, 46626), (67, 54806)]
    equalised = mean_clahe(stack)
    assert float(equalised.sum()) == 297239 and list(equalised[20, 10:16]) == [139, 207, 160, 231, 219, 171]
