"""A file method, as NANSEN dev's project filemethod.downloadFile: on the file viewer's menu of every file."""

import shutil
from pathlib import Path


def download_file(file, options, context):
    """Fetch a file that is only a placeholder here (an empty file) from the archive, which is laid out as the file's
    root (dev's downloadFile(filePath, rootPath)); a file that is here already is left as it is."""
    path, root = Path(file["path"]), Path(file["root"])
    if path.stat().st_size > 0:
        context.log(f"{path.name} is here already")
        return {"downloaded": False, "bytes": path.stat().st_size}
    shutil.copyfile(Path(options["archive"]) / path.relative_to(root), path)
    context.log(f"downloaded {path.name}")
    return {"downloaded": True, "bytes": path.stat().st_size}
