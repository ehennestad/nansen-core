"""The add-on manager, as dev's AddonManager: the toolboxes and packages modules declare, listed and installed.

A module lists them under ``addons`` in ``module.nansen.json``. One from GitHub is downloaded into the add-ons
folder (``~/.nansen/addons`` unless the settings say otherwise), where MATLAB puts it on its path when an app or
API starts; one from pip is installed into the running Python; one from conda is not installed by NANSEN, which
says how to. MATLAB's nansen.Addons does the same for MATLAB.
"""

from __future__ import annotations

import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .errors import NansenError

MARKER = ".nansen-addon.json"


def default_folder() -> Path:
    return Path.home() / ".nansen" / "addons"


def declared(modules) -> List[dict]:
    """The add-ons the modules declare, each with the module that declares it (the first module's, for an id two declare)."""
    found: Dict[str, dict] = {}
    for module in modules:
        for addon in module.document.get("addons", []):
            found.setdefault(addon["id"], dict(addon, module=module.id))
    return list(found.values())


def find(addons: List[dict], addon_id: str) -> dict:
    for addon in addons:
        if addon["id"] == addon_id:
            return addon
    raise NansenError("unknown-addon", f"no module of the project declares an add-on {addon_id!r}")


def status(addon: dict, folder: Path) -> Dict[str, Any]:
    """What the add-on is and whether it is installed: True or False for a Python add-on, and for a MATLAB one
    whether it was downloaded into the folder (None when it comes from somewhere else that Python cannot see)."""
    kind, spec = next(iter(addon["source"].items()))
    location = folder / addon["id"]
    downloaded = (location / MARKER).is_file()
    if addon["language"] == "python":
        installed: Optional[bool] = importlib.util.find_spec(addon["check"]) is not None
    else:
        installed = True if downloaded else None
    how = {"github": f"downloaded from https://github.com/{spec} into the add-ons folder",
           "pip": f"pip install {spec!r}",
           "conda": f"conda install -c conda-forge {spec}"}[kind]
    return {"id": addon["id"], "title": addon["title"], "description": addon.get("description", ""),
            "language": addon["language"], "module": addon.get("module"), "url": addon.get("url"),
            "source": kind, "spec": spec, "check": addon["check"], "installed": installed,
            "location": str(location) if downloaded else None,
            "installable": kind == "github" or (kind == "pip" and addon["language"] == "python"),
            "removable": downloaded, "how": how}


def install(addon: dict, folder: Path, archive: Optional[str] = None,
            run: Callable[..., Any] = subprocess.run) -> Path:
    """Install the add-on; archive is a local .zip (for a GitHub add-on) or file (for pip) to use instead of the
    internet. Returns where it is."""
    kind, spec = next(iter(addon["source"].items()))
    if kind == "github":
        data = Path(archive).read_bytes() if archive else _download(f"https://codeload.github.com/{spec}/zip/HEAD")
        target = folder / addon["id"]
        with tempfile.TemporaryDirectory() as scratch:
            try:
                zipfile.ZipFile(io.BytesIO(data)).extractall(scratch)
            except zipfile.BadZipFile:
                raise NansenError("install-failed", f"the download of {spec} is not a zip archive") from None
            entries = [p for p in Path(scratch).iterdir()]
            top = entries[0] if len(entries) == 1 and entries[0].is_dir() else Path(scratch)   # GitHub's archives hold one folder
            if target.exists():
                shutil.rmtree(target)
            folder.mkdir(parents=True, exist_ok=True)
            shutil.copytree(top, target)
        (target / MARKER).write_text(json.dumps({"id": addon["id"], "source": addon["source"],
                                                 "pathOrder": addon.get("pathOrder", "begin"),
                                                 "setup": addon.get("setup")}, indent=2) + "\n", encoding="utf-8")
        return target
    if kind == "pip" and addon["language"] == "python":
        done = run([sys.executable, "-m", "pip", "install", archive or spec], capture_output=True, text=True)
        if done.returncode != 0:
            raise NansenError("install-failed", f"pip install {archive or spec} failed: {(done.stderr or done.stdout)[-800:]}")
        importlib.invalidate_caches()
        return Path(sys.prefix)
    how = status(addon, folder)["how"]
    raise NansenError("install-failed", f"{addon['title']} is not installed by NANSEN here; install it with: {how}")


def remove(addon: dict, folder: Path) -> None:
    """Delete a downloaded add-on from the add-ons folder (pip packages are removed with pip)."""
    target = folder / addon["id"]
    if not (target / MARKER).is_file():
        raise NansenError("install-failed", f"{addon['title']} was not downloaded into {folder}, so NANSEN does not remove it")
    shutil.rmtree(target)


def _download(url: str) -> bytes:
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            return response.read()
    except OSError as error:
        raise NansenError("install-failed", f"cannot download {url}: {error}") from None
