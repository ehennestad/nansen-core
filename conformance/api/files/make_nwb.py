"""Writes project/data/recording.nwb, a small file laid out like NWB, for files.inspect.

Run with h5py installed: python make_nwb.py. Plain h5py, so the case does not need pynwb.
"""
from pathlib import Path

import h5py
import numpy as np

path = Path(__file__).parent / "project" / "data" / "recording.nwb"
path.parent.mkdir(parents=True, exist_ok=True)
text = h5py.string_dtype()
with h5py.File(path, "w", track_order=False) as f:
    f.attrs["neurodata_type"] = "NWBFile"
    f.attrs["namespace"] = "core"
    f.attrs["nwb_version"] = "2.7.0"
    f.create_dataset("identifier", data="m1-s1", dtype=text)
    f.create_dataset("session_description", data="Two-photon imaging", dtype=text)
    plane = f.create_group("general/optophysiology/ImagingPlane")
    plane.attrs["neurodata_type"] = "ImagingPlane"
    plane.create_dataset("excitation_lambda", data=np.float32(920.0))
    series = f.create_group("acquisition/TwoPhotonSeries")
    series.attrs["neurodata_type"] = "TwoPhotonSeries"
    series.attrs["description"] = "raw frames"
    data = series.create_dataset("data", data=np.arange(4 * 3 * 5, dtype=np.uint16).reshape(4, 3, 5))
    data.attrs["unit"] = "n.a."
    data.attrs["conversion"] = 1.0
    series.create_dataset("timestamps", data=np.arange(4, dtype=np.float64) / 30.0)
    series["imaging_plane"] = h5py.SoftLink("/general/optophysiology/ImagingPlane")
    f.create_dataset("processing/ophys/Fluorescence/RoiResponseSeries/data", data=np.zeros((4, 2), dtype=np.float64))
