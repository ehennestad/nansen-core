function doc = readJson(path)
%readJson Decode a JSON file, raising file-not-found or malformed-json
    arguments
        path (1,1) string
    end
    text = nansen.internal.readText(path);
    if ~isempty(text) && text(1) == char(65279)
        nansen.internal.throwError("malformed-json", "%s starts with a byte order mark", path)
    end
    try
        doc = jsondecode(text);
    catch err
        nansen.internal.throwError("malformed-json", "%s: %s", path, err.message)
    end
end
