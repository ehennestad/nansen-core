# How the rebuild is verified

Every claim in [parity.md](parity.md) and [dashboard.md](dashboard.md) rests on tests that run on each push to `main`
(`.github/workflows/ci.yml`). This page says what runs where, and records the results of the run that the parity matrix
was last checked against.

## What runs

| Job | What it runs |
|---|---|
| MATLAB tests and conformance (R2023a, latest) | `runNansenCoreTests`: the MATLAB unit tests in `matlab/tests` and every conformance case through `nansen.conformance.runCase` (`ConformanceTest`), then DSM's MATLAB tests |
| Python tests and conformance (3.9, 3.13) | `pytest python/tests` (without the browser) and `nansen conformance`: every case of `conformance/` |
| Dashboard in a browser | `pytest python/tests/test_ui.py python/tests/test_server.py`: Playwright drives the dashboard in Chromium against a Python backend |
| External tools (MATLAB R2024b, latest) | `matlab/externaltests/ExternalToolsTest.m`: each MATLAB wrapper against the real toolbox (CNMF, NWB export, NoRMCorre, FlowReg, EXTRACT, Suite2P, DeepInterpolation, CaImAn, flufinder, imviewer) |
| External tools (Python), External tools (CaImAn) | each Python wrapper against the real package (suite2p, DeepInterpolation, pynwb, CaImAn's CNMF, deconvolution and NoRMCorre) |

The conformance suite is the cross-language contract: the same requests, with the same expected responses, run by the
Python and the MATLAB implementation; [parity.md](parity.md#cross-language-identity) lists the algorithms it holds
identical. MATLAB is not installed where the code was written; CI is where it runs, on the oldest release supported
(R2023a) and the latest.

## The run the matrix was checked against

Commit `96038cc`, run [38843246897](https://github.com/ehennestad/nansen-core/actions/runs/38843246897): every job passed.

| Job | Result |
|---|---|
| MATLAB tests and conformance (R2023a) | 320 passed, 0 failed, 1 incomplete: `ApiTest/appAnswersTheDashboard`, filtered by its assumption because a headless R2023a does not run a `uihtml` page (it runs on the latest release); DSM: 51 passed |
| MATLAB tests and conformance (latest, R2026b) | 321 passed, 0 failed, 0 incomplete; DSM: 51 passed |
| External tools (MATLAB R2024b) | 10 of 10 passed |
| External tools (MATLAB latest, R2026b) | 10 of 10 passed |
| Python tests and conformance (3.9, 3.13) | passed (604 tests in the full local run with the browser tests; 90 of 90 conformance cases) |
| Dashboard in a browser | passed |
| External tools (Python), External tools (CaImAn) | passed |

## Independent checks

Two audits, each by a reviewer that had not written the code, built an inventory of dev's features from dev's source
and looked for each in the rebuild; the second also ran MATLAB functions in Octave beside their Python counterparts
(autodetection modes, CLAHE, AR(1) and AR(2) deconvolution, neuropil masks: identical outputs). Every gap they found
is closed or listed, with its reason, in [parity.md](parity.md).
