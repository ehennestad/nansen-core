function writeSessionMethods(folder, entries)
%writeSessionMethods Write planned dev session methods into a project folder
%
%   nansen.legacy.writeSessionMethods(folder, entries) writes each entry of
%   nansen.legacy.planSessionMethods: its code under matlab/ (in its
%   packages) and its document in methods/. As Python's
%   nansen.legacymethods.write.
    arguments
        folder (1,1) string
        entries (1,:) cell
    end
    for i = 1:numel(entries)
        entry = entries{i};
        path = fullfile(folder, "matlab", entry.file);
        if ~isfolder(fileparts(path))
            mkdir(fileparts(path));
        end
        nansen.internal.writeText(path, entry.text);
        if ~isfolder(fullfile(folder, "methods"))
            mkdir(fullfile(folder, "methods"));
        end
        nansen.internal.writeJson(fullfile(folder, "methods", string(entry.document.id) + ".method.nansen.json"), entry.document)
    end
    if ~isempty(entries)
        rehash   % new files in a folder already on the path are seen at once
    end
end
