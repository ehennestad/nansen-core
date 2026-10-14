function copyDataset(source, target)
%copyDataset Copy a DSM config, making its relative root paths absolute so they still point there
%
%   Only those path values change in the text (nansen.internal.JsonText),
%   as in Python's nansen.dataset.copy_dataset.
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
    locations = nansen.internal.asCellOfStructs(nansen.internal.getField(config, "dataLocations", []));
    for i = 1:numel(locations)
        filesystem = nansen.internal.getField(locations{i}, "filesystemSource", struct());
        roots = nansen.internal.asCellOfStructs(nansen.internal.getField(filesystem, "rootStoragePaths", []));
        for j = 1:numel(roots)
            path = nansen.internal.getField(roots{j}, "path", []);
            if ~(ischar(path) || isstring(path)) || nansen.internal.isAbsolutePath(string(path))
                continue
            end
            absolute = nansen.internal.normalizePath(folder + "/" + string(path));
            pointer = sprintf("/dataLocations/%d/filesystemSource/rootStoragePaths/%d/path", i - 1, j - 1);
            text = nansen.internal.JsonText.replace(text, pointer, absolute);
        end
    end
    nansen.internal.writeText(target, text);
end
