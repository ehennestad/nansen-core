"""Entity methods: declarations, options, presets, and running them."""

from __future__ import annotations

import copy
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from jsonschema import Draft7Validator

from .adapters import load_object
from .errors import NansenError

EMPTY_OPTIONS = {"type": "object", "properties": {}}


PROJECT_TOOL = "@project"  # the entityType of a method that runs once on the project

class Method:
    """A nansen.method declaration, with the folder its Python code is imported from."""

    def __init__(self, document: dict, python_root: Optional[Path] = None, matlab_root: Optional[Path] = None,
                 module: Optional[str] = None):
        self.document = document
        self.python_root = python_root
        self.matlab_root = matlab_root
        self.module = module
        self._function: Optional[Callable] = None

    def __repr__(self) -> str:
        return f"Method({self.id})"

    @property
    def id(self) -> str:
        return self.document["id"]

    @property
    def version(self) -> str:
        return self.document["version"]

    @property
    def title(self) -> str:
        return self.document.get("title", self.id)

    @property
    def entity_type(self) -> str:
        return self.document["entityType"]

    def applies_to(self, entity_type: str) -> bool:
        return not self.is_tool and self.entity_type in ("*", entity_type)

    @property
    def is_tool(self) -> bool:
        """A project tool runs once on the project, not on entities."""
        return self.entity_type == PROJECT_TOOL

    @property
    def batch_mode(self) -> str:
        return self.document.get("batchMode", "serial")

    @property
    def queueable(self) -> bool:
        return self.document.get("queueable", True)

    @property
    def languages(self) -> List[str]:
        return sorted(self.document["implementations"])

    @property
    def options_schema(self) -> dict:
        return self.document.get("options", EMPTY_OPTIONS)

    def default_options(self) -> dict:
        return defaults_of(self.options_schema)

    def resolve_options(self, values: Optional[dict] = None) -> dict:
        """The defaults overlaid with the given values, validated against the options schema."""
        options = merge(self.default_options(), values or {})
        errors = sorted(Draft7Validator(self.options_schema).iter_errors(options), key=lambda e: list(e.absolute_path))
        if errors:
            details = "; ".join(f"[{'/'.join(map(str, e.absolute_path)) or '$'}] {e.message}" for e in errors)
            raise NansenError("invalid-options", f"{self.id}: {details}")
        return options

    def function(self) -> Callable:
        if self._function is None:
            reference = self.document["implementations"].get("python")
            if reference is None:
                raise NansenError("method-unavailable", f"method {self.id!r} has no Python implementation")
            self._function = load_object(reference, self.python_root)
        return self._function

    def summary(self) -> dict:
        return {"id": self.id, "version": self.version, "title": self.title, "entityType": self.entity_type,
                "description": self.document.get("description", ""), "category": self.document.get("category", ""),
                "batchMode": self.batch_mode, "queueable": self.queueable, "languages": self.languages,
                "module": self.module, "options": self.options_schema, "tool": self.is_tool}


def defaults_of(schema: dict) -> Any:
    """The default value a schema gives: its own default, or an object of its properties' defaults."""
    if "default" in schema:
        return copy.deepcopy(schema["default"])
    if schema.get("type") == "object" or "properties" in schema:
        out = {}
        for name, sub in schema.get("properties", {}).items():
            value = defaults_of(sub)
            if value is not None:
                out[name] = value
        return out
    return None


def merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


class Cancelled(Exception):
    """Raised inside a method by context.check_cancelled() when the run was cancelled."""


class MethodContext:
    """What a running method gets besides its entity and options: the project, a log, progress and cancellation.

    Observers (callables) are told about log lines and progress; nothing is global.
    """

    def __init__(self, project=None, method: Optional[Method] = None,
                 on_log: Optional[Callable[[str], None]] = None,
                 on_progress: Optional[Callable[[float, str], None]] = None,
                 cancel_event: Optional[threading.Event] = None):
        self.project = project
        self.method = method
        self.lines: List[str] = []
        self.fraction = 0.0
        self._on_log = on_log
        self._on_progress = on_progress
        self._cancel = cancel_event or threading.Event()

    def log(self, message: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {message}"
        self.lines.append(line)
        if self._on_log:
            self._on_log(line)

    def progress(self, fraction: float, message: str = "") -> None:
        self.fraction = max(0.0, min(1.0, float(fraction)))
        if self._on_progress:
            self._on_progress(self.fraction, message)

    def cancel(self) -> None:
        self._cancel.set()

    @property
    def cancelled(self) -> bool:
        return self._cancel.is_set()

    def check_cancelled(self) -> None:
        if self.cancelled:
            raise Cancelled()


def run_tool(method: Method, project, options: Optional[dict] = None, context: Optional[MethodContext] = None) -> Any:
    """Run a project tool in this process: once, as function(project, options, context)."""
    if not method.is_tool:
        raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}, not on the project")
    context = context or MethodContext(project=project, method=method)
    resolved = method.resolve_options(options)
    context.check_cancelled()
    result = method.function()(project, resolved, context)
    context.progress(1.0)
    return result


def run_method(method: Method, entities: List[Any], options: Optional[dict] = None,
               context: Optional[MethodContext] = None) -> List[Any]:
    """Run a method in this process: once per entity (serial) or once for all (batch). Returns the results."""
    if not entities:
        return []
    wrong = [e for e in entities if not method.applies_to(e.entity_type)]
    if wrong:
        raise NansenError("wrong-entity-type", f"{method.id} runs on {method.entity_type}, not {wrong[0].entity_type}")
    context = context or MethodContext(method=method)
    resolved = method.resolve_options(options)
    function = method.function()
    if method.batch_mode == "batch":
        context.check_cancelled()
        result = [function(list(entities), resolved, context)]
        context.progress(1.0)
        return result
    results = []
    for number, entity in enumerate(entities):
        context.check_cancelled()
        results.append(function(entity, resolved, context))
        context.progress((number + 1) / len(entities))
    return results
