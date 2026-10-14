function copyDataset(source, target)
%copyDataset Copy a DSM config, making its relative root paths absolute so they still point there
%
%   Only those path values change in the text, as in Python's
%   nansen.dataset.copy_dataset: MATLAB cannot write decoded JSON back
%   unchanged.
    if ~isfile(source)
        nansen.internal.throwError("file-not-found", "no DSM config %s", source)
    end
    text = string(nansen.internal.readText(source));
    try
        config = jsondecode(char(text));
    catch err
        nansen.internal.throwError("malformed-json", "%s: %s", source, err.message)
    end
    listing = dir(source);
    folder = string(listing(1).folder);
    for location = nansen.internal.asCellOfStructs(nansen.internal.getField(config, "dataLocations", []))
        filesystem = nansen.internal.getField(location{1}, "filesystemSource", struct());
        for root = nansen.internal.asCellOfStructs(nansen.internal.getField(filesystem, "rootStoragePaths", []))
            path = nansen.internal.getField(root{1}, "path", []);
            if ~(ischar(path) || isstring(path)) || nansen.internal.isAbsolutePath(string(path))
                continue
            end
            absolute = nansen.internal.normalizePath(folder + "/" + string(path));
            pattern = "(""path""\s*:\s*)" + regexptranslate("escape", jsonencode(char(path)));
            replacement = replace(replace(string(jsonencode(char(absolute))), "\", "\\"), "$", "\$");
            text = regexprep(text, pattern, "$1" + replacement);
        end
    end
    nansen.internal.writeText(target, text);
end
