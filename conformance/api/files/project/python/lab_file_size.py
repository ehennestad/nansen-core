"""A file method for some files only: .bin and .dat files with something in them (its files)."""

from pathlib import Path


def file_size(file, options, context):
    """The file's size in bytes."""
    return {"bytes": Path(file["path"]).stat().st_size}
