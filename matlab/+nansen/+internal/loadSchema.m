function schema = loadSchema(schemaType)
%loadSchema The decoded JSON Schema for a schemaType
    entry = nansen.internal.schemaEntry(schemaType);
    if isempty(entry)
        error("nansen:schema:UnknownType", "Unknown schemaType %s", schemaType)
    end
    schema = nansen.internal.readJson(fullfile(nansen.internal.repoRoot(), "schema", entry.file));
end
