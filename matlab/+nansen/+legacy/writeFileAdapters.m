function writeFileAdapters(folder, entries)
%writeFileAdapters Write planned dev file adapters into a project folder
%
%   nansen.legacy.writeFileAdapters(folder, entries) writes each entry of
%   nansen.legacy.planFileAdapters: its code under matlab/ (in its
%   packages) and its document in file-adapters/. As Python's
%   nansen.legacyadapters.write.
    arguments
        folder (1,1) string
        entries (1,:) cell
    end
    for i = 1:numel(entries)
        entry = entries{i};
        for k = 1:numel(entry.files)
            path = fullfile(folder, "matlab", entry.files{k}.path);
            if ~isfolder(fileparts(path))
                mkdir(fileparts(path));
            end
            nansen.internal.writeText(path, entry.files{k}.text);
        end
        if ~isfolder(fullfile(folder, "file-adapters"))
            mkdir(fullfile(folder, "file-adapters"));
        end
        nansen.internal.writeJson(fullfile(folder, "file-adapters", string(entry.document.id) + ".fileAdapter.nansen.json"), ...
            entry.document)
    end
    if ~isempty(entries)
        rehash   % new files in a folder already on the path are seen at once
    end
end
