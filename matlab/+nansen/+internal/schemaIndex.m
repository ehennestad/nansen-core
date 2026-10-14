function entries = schemaIndex()
%schemaIndex The entries of schema/index.json: schemaType, file, version, status
%
%   Read from disk on every call. The files are small, and keeping no cache
%   means no persistent state.
    index = nansen.internal.readJson(fullfile(nansen.internal.repoRoot(), "schema", "index.json"));
    entries = index.schemas;
end
