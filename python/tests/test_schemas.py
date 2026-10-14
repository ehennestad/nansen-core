"""The schema files themselves: valid, indexed, and written in the keyword subset the MATLAB validator implements."""

import json

import pytest
from jsonschema import Draft7Validator

from nansen.documents import parse_version
from nansen.schemas import load_schema, schema_dir, schema_index

# Keep in step with matlab/+nansen/+internal/schemaValidationErrors.m
MATLAB_KEYWORDS = {
    "type", "required", "properties", "additionalProperties", "propertyNames", "minProperties",
    "items", "minItems", "uniqueItems", "enum", "const", "pattern", "default", "examples",
    "allOf", "anyOf", "oneOf", "if", "then", "else", "not", "definitions", "title", "description",
    "$ref", "$schema", "$id",
}

TYPES = sorted(schema_index())


def keywords(node, found):
    if isinstance(node, dict):
        for key, value in node.items():
            found.add(key)
            if key in ("properties", "definitions"):
                for sub in value.values():
                    keywords(sub, found)
            elif key in ("const", "enum", "default", "examples", "required", "description", "title", "pattern"):
                continue
            else:
                keywords(value, found)
    elif isinstance(node, list):
        for item in node:
            keywords(item, found)
    return found


@pytest.mark.parametrize("schema_type", TYPES)
def test_schema_is_valid_draft7(schema_type):
    Draft7Validator.check_schema(load_schema(schema_type))


@pytest.mark.parametrize("schema_type", TYPES)
def test_schema_uses_keywords_the_matlab_validator_knows(schema_type):
    assert keywords(load_schema(schema_type), set()) <= MATLAB_KEYWORDS


@pytest.mark.parametrize("schema_type", TYPES)
def test_envelope_matches_index(schema_type):
    schema = load_schema(schema_type)
    entry = schema_index()[schema_type]
    assert schema["properties"]["schemaType"] == {"const": schema_type}
    assert {"schemaType", "schemaVersion"} <= set(schema["required"])
    assert parse_version(entry["version"]) is not None
    assert entry["status"] in ("core", "draft")
    validator = Draft7Validator(schema["properties"]["schemaVersion"])
    assert validator.is_valid(entry["version"])
    major, minor, _ = parse_version(entry["version"])
    assert not validator.is_valid(f"{major}.{minor + 1}.0")


def test_every_schema_file_is_indexed():
    indexed = {entry["file"] for entry in schema_index().values()}
    on_disk = {p.name for p in schema_dir().glob("*.schema.json")}
    assert indexed == on_disk


def test_schema_files_are_pretty_and_end_with_newline():
    for path in schema_dir().glob("*.json"):
        text = path.read_text()
        assert text.endswith("\n"), path
        json.loads(text)
