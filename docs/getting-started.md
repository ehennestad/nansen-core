# Getting started: the two-photon quickstart

This walkthrough takes a small two-photon project through the standard processing steps in the dashboard: motion correction, ROI detection, signal extraction and ΔF/F. It is the rebuild's version of NANSEN's *Two-photon Quickstart* tutorial (`GettingStarted.mlx`). It needs no download: the recordings are made on your machine.

## 1. Create the tutorial

Open the dashboard with no project:

- Python: `nansen app` (needs numpy: `pip install -e ".[ophys]"`)
- MATLAB: `nansen.App`

On the welcome page, choose **Create the demo**. Set **Demo** to **Two-photon quickstart**, give a new or empty folder, and press **Create**. The project opens on its overview: 2 subjects and 4 sessions.

The same project can be made without the dashboard:

```bash
nansen demo --kind two-photon /tmp/quickstart
nansen app /tmp/quickstart
```

```matlab
project = nansen.demo.createTwoPhoton(fullfile(tempdir, "quickstart"));
app = nansen.App(Project=project.Folder);
```

In the protocol it is `demo.create {path, kind: "two-photon"}`.

### Viewing a file without a project

To look at a recording, an array or a set of signals without making a project, as dev's `imviewer(file)`,
`imviewer(array)`, `signalviewer` and `roimanager` from the command line:

```bash
nansen view recording.tif                       # any stack file: TIFF, .npy, SciScan .raw, HDF5, video, ...
nansen view recording.raw --rois rois.json      # with ROIs over it, edited and saved back to rois.json
nansen view --signals dff.npy --frame-rate 31.25   # frames x N signals in the trace plot (a .mat: --variable)
```

```python
import nansen
server = nansen.view(movie)                     # an array, height x width (x channels (x planes)) x frames
server = nansen.view(signals=dff)               # frames x N
```

```matlab
app = nansen.view(movie);
app = nansen.view("recording.tif", Rois="rois.json");
app = nansen.view([], Signals=dff, FrameRate=31.25);
```

The dashboard opens straight into the viewer, with its projections, binning, filters, colour channels and export.
Only what was given can be read by the page. ROIs are drawn, detected, found (Find ROIs) and edited as in a project,
as dev's roimanager does on any file: they are saved to the ROI file given, or to `<stem>_rois.json` beside the stack
(read again the next time the file is viewed); an array's are kept while the app is open. Run… on the Viewer page runs
a built-in method on a stack, such as motion correction (dev's Align Images): what it saves is written beside the file
as `<stem>_<variable>.npy` or `.json`, and the aligned stack (or the ROIs found) is listed to be opened in turn.

### What is in it

```
quickstart/
  dataset.dsm.json            raw recordings in data/raw/sub-<subject>/ses-<session>, processed data in data/processed
  data/raw/sub-m1/ses-s1/     rec.raw + rec.ini: a SciScan recording
  data/raw/sub-m1/ses-s2/
  data/raw/sub-m2/...
  project.nansen.json         the core and ophys modules
  data-variables/             TwoPhotonSeries_Original (the raw recording) and the variables the ophys methods write
```

Each recording is 64 × 64 pixels and 300 frames at 31.25 frames per second, with 2 µm pixels. It shows 12 round cells on a textured background. The cells fire now and then, and their calcium decays over a few frames. The image moves by whole pixels, up to 3 either way, so motion correction has work to do. There is noise on every frame. The two sessions of a subject show the same field of view, with different activity and motion.

The recordings are synthetic. Every random number comes from a 32-bit hash, so Python and MATLAB write the same bytes, and a conformance case checks that they do. What is drawn is set in the ophys module's [`tutorial/tutorial.json`](../modules/ophys/tutorial/tutorial.json).

When the tutorial was made, it also:

- ran **Set up two-photon variables** (`ophys.setup_variables`) with the raw file pattern `recording`;
- filled the sessions' frame rate and pixel size from the `.ini` files (`ophys.read_metadata`);
- saved a preset, `tutorial`, for **Detect ROIs (Quicky)**.

## 2. Look at a raw recording

Open **Sessions** and click a row's key. The drawer lists the session's folders, files and data variables. Press the image button next to **TwoPhotonSeries_Original** to open the viewer.

- Use the slider, or **Play**, to go through the frames. The image moves.
- Set the mode to **Maximum** or **Average**. The cells come out blurred, because the image moved under them.

## 3. Run the pipeline

The ophys module's **Two-photon preprocessing** pipeline (`ophys.preprocess`) runs six steps: correct motion, image statistics, detect ROIs, extract signals, compute ΔF/F and deconvolve.

1. In **Sessions**, select all rows (click the first, shift-click the last).
2. Choose **Pipeline** in the selection bar, then **Two-photon preprocessing**.
3. Open the menu again and choose **Queue the next steps**.
4. Open **Tasks**. If the worker is stopped, press **Start worker**, or **Run next** to run one task at a time.

Each session's drawer shows how far its pipeline has come.

### Or run the methods one by one

Select sessions and press **Run method**. Choose a method, check its options and press **Run now**, or **Add to queue** to run it in the background. Use this order:

1. **Correct motion**: writes `TwoPhotonSeries_Corrected` and `MotionCorrectionShifts`.
2. **Image statistics**: the average and maximum projections, and the frames, size and intensity columns.
3. **Detect ROIs** (`ophys.detect_rois`): finds the 12 cells in each session with its default options. **Detect ROIs (Quicky)** works too, with its `tutorial` preset, because the cells are smaller than its default diameter.
4. **Extract signals**: each ROI's mean in every frame, and its neuropil.
5. **Compute ΔF/F**, then **Deconvolve (OASIS)**.

To try an option before running a method, select one session and press **Preview**.

## 4. View the stack and the ROIs

Open a session's drawer again. Press the image button of **TwoPhotonSeries_Corrected**. The ROIs of `RoiArray` are drawn over the frames.

- The cells now stay in place. Compare **Maximum** with the raw recording's maximum, or press the link button and pick **TwoPhotonSeries_Original** to see the raw frames beside the corrected ones, at the same frame, zoom and pan.
- **Local correlation** shows the cells that ROI detection found: they are the pixels whose activity matches their neighbours'.
- Click an ROI to select it. Its trace is shown under the image.

## 5. Curate the ROIs

In the viewer, with an ROI selected:

| To | Do |
| --- | --- |
| Accept, reject or unclassify it | `a`, `r`, `u` |
| Go to the next or previous ROI | `↓`, `↑` |
| Grow or shrink it by a pixel | `+`, `-` |
| Merge several (Ctrl-click to select them) | `m` |
| Show its neuropil, as signal extraction takes it | Shift+N |
| Delete it | `Delete` |
| Undo or redo | Ctrl+Z, Ctrl+Shift+Z |

You can also add an ROI: as a circle, drawn freehand, or detected around a click.

The grid button opens the **gallery**: one tile per ROI, which you can sort by area, brightness or peak ΔF/F, and classify with the same keys. Run **ROI images and statistics** (`ophys.roi_images`) on the session to also see each ROI's activity-weighted image and local correlation, and to sort the tiles by salience.

Rejected ROIs are left out when signals are extracted again.

## 6. Look at the traces

In the drawer, press the plot button next to **RoiSignals_Dff**, or next to any other signal variable. Pick the ROIs and variables to plot. Drag across a panel to zoom in on those frames; double-click to see all frames again. Time is in seconds, from the session's frame rate.

Plot `RoiSignals_Dff` with `RoiSignals_Denoised` to compare ΔF/F with the deconvolved calcium.

## 7. Across sessions

The two sessions of a subject image the same cells. Select both of `m1`'s sessions and run **Align sessions and copy ROIs** (`ophys.align_sessions`). It aligns the second session's image to the first's, and saves the first session's ROIs, moved by that shift, as the second's, with the same ids. Then open the **ROI review** page under **Modules**. It shows each ROI in every session side by side, and you classify it in all of them at once.

## The same in code

```python
from nansen.demo import create_two_photon_demo

project = create_two_photon_demo("/tmp/quickstart")
sessions = project.entities("session")
for method in ["ophys.motion_correction", "ophys.image_stats", "ophys.detect_rois",
               "ophys.extract_signals", "ophys.compute_dff", "ophys.deconvolve"]:
    project.run(method, sessions)
dff = project.load(sessions[0], "RoiSignals_Dff")   # frames x ROIs
```

```matlab
project = nansen.demo.createTwoPhoton(fullfile(tempdir, "quickstart"));
sessions = project.entities("session");
for method = ["ophys.motion_correction", "ophys.image_stats", "ophys.detect_rois", ...
        "ophys.extract_signals", "ophys.compute_dff", "ophys.deconvolve"]
    project.run(method, sessions);
end
dff = project.load(sessions{1}, "RoiSignals_Dff");   % frames x ROIs
```

Next, see [the ophys module](reference/modules.md#the-ophys-module) for every method and its options.
