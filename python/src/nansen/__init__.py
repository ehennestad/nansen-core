"""NANSEN core: versioned project, fragment and table documents."""

from .csvio import Field, format_csv, parse_csv
from .documents import DEFAULT_MIGRATIONS, Migration, check_document, parse_version, read_document
from .errors import NansenError
from .numbers import format_number
from .project import Fragment, Project
from .tables import Column, EntityTable, TableSpec

__version__ = "0.1.0"


def view(data=None, **options):
    """Open the dashboard's viewer on image stacks or signals, with no project (dev's imviewer and signalviewer):
    nansen.view(array), nansen.view("recording.tif", rois="rois.json"), nansen.view(signals=traces). Returns the
    server without blocking; see nansen.viewables.view for the options."""
    from .viewables import view as open_viewer

    return open_viewer(data, **options)


__all__ = [
    "Column",
    "DEFAULT_MIGRATIONS",
    "EntityTable",
    "Field",
    "Fragment",
    "Migration",
    "NansenError",
    "Project",
    "TableSpec",
    "check_document",
    "format_csv",
    "format_number",
    "parse_csv",
    "parse_version",
    "read_document",
    "view",
]
