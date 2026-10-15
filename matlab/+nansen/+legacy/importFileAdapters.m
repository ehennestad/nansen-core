function result = importFileAdapters(project, path)
%importFileAdapters Import NANSEN dev file adapters into a project, to read and write with dev's code in MATLAB
%
%   result = nansen.legacy.importFileAdapters(project, path) imports the
%   class file adapter of a .m file (a subclass of nansen.dataio.FileAdapter),
%   dev's function-based adapter of a folder with fileadapter.json, or
%   those of a folder and its package folders (+name), such as a dev
%   project's code/+<name>/+fileadapter. The code is copied into the
%   project's matlab/ folder, in the same packages, and each adapter gets a
%   document (file-adapters/legacy.<name>.fileAdapter.nansen.json) with
%   legacyFileAdapter, read from its text (nansen.legacy.analyzeFileAdapter).
%   The adapter registry reads and writes with it through
%   nansen.legacy.FileAdapterShim. Project.importAdapter calls this for
%   such a path (and then reads the project's adapters again).
%
%   result has adapters (each document, with its files) and warnings (the
%   files of a folder that are not file adapters). file-not-found,
%   unsupported-file (a file that is not a dev file adapter, or a folder
%   with none), adapter-exists (an id or file is taken; nothing is
%   written). As Python's nansen.legacyadapters.import_into.
    arguments
        project (1,1) nansen.Project
        path (1,1) string
    end
    folder = string(project.Folder);
    sources = sourcesAt(path);
    if isfile(path)   % the reason a file is not a file adapter is the error
        [~, stem] = fileparts(path);
        nansen.legacy.analyzeFileAdapter(string(stem), sources{1}.text);
    end
    [entries, warnings] = nansen.legacy.planFileAdapters(sources);
    if isempty(entries)
        nansen.internal.throwError("unsupported-file", "%s holds no dev file adapters", path)
    end
    existing = reshape(project.adapters().ids(), 1, []);
    clashes = strings(1, 0);
    for i = 1:numel(entries)
        id = string(entries{i}.document.id);
        if ismember(id, existing)
            clashes(end + 1) = "a file adapter '" + id + "'"; %#ok<AGROW>
        end
    end
    for i = 1:numel(entries)
        for k = 1:numel(entries{i}.files)
            file = entries{i}.files{k};
            target = fullfile(folder, "matlab", file.path);
            if isfile(target) && string(nansen.internal.readText(target)) ~= string(file.text)
                clashes(end + 1) = "matlab/" + file.path; %#ok<AGROW>
            end
        end
    end
    for i = 1:numel(entries)
        id = string(entries{i}.document.id);
        if isfile(fullfile(folder, "file-adapters", id + ".fileAdapter.nansen.json"))
            clashes(end + 1) = "file-adapters/" + id + ".fileAdapter.nansen.json"; %#ok<AGROW>
        end
    end
    if ~isempty(clashes)
        nansen.internal.throwError("adapter-exists", "the project already has %s", strjoin(unique(clashes, "stable"), ", "))
    end
    nansen.legacy.writeFileAdapters(folder, entries);
    adapters = cell(1, numel(entries));
    for i = 1:numel(entries)
        document = entries{i}.document;
        files = "file-adapters/" + string(document.id) + ".fileAdapter.nansen.json";
        for k = 1:numel(entries{i}.files)
            files(end + 1) = "matlab/" + entries{i}.files{k}.path; %#ok<AGROW>
        end
        document.files = cellstr(files);
        adapters{i} = document;
    end
    result = struct("adapters", {adapters}, "warnings", {warnings});
end

function sources = sourcesAt(path)
    % {file, text} of a dev file adapter: a .m file, a folder with fileadapter.json, or each in a folder and its
    % package folders. The paths start at the outermost package folder (+name) above, so the names come out right.
    if isfile(path)
        [parent, stem, extension] = fileparts(path);
        if extension ~= ".m"
            nansen.internal.throwError("unsupported-file", "%s is not a MATLAB file (.m)", path)
        end
        sources = {struct("file", prefixOf(parent) + stem + extension, "text", string(nansen.internal.readText(path)))};
        return
    end
    if ~isfolder(path)
        nansen.internal.throwError("file-not-found", "no file or folder %s", path)
    end
    found = walk(path, prefixOf(path));
    [~, order] = sort(found(:, 1));
    found = found(order, :);
    sources = cell(1, size(found, 1));
    for i = 1:size(found, 1)
        sources{i} = struct("file", found(i, 1), "text", string(nansen.internal.readText(found(i, 2))));
    end
end

function prefix = prefixOf(folder)
    % The package folders (+name) a folder is in, itself included, as +a/+b/
    parts = reshape(split(replace(string(folder), "\", "/"), "/"), 1, []);
    prefix = "";
    for k = numel(parts):-1:1
        if ~startsWith(parts(k), "+") || strlength(parts(k)) < 2
            break
        end
        prefix = parts(k) + "/" + prefix;
    end
end

function found = walk(folder, relative)
    % [path, absolute path] of the .m files and fileadapter.json in a folder and its package folders (N-by-2 string)
    found = strings(0, 2);
    listing = dir(folder);
    names = string({listing.name});
    [names, order] = sort(names);
    listing = listing(order);
    for i = 1:numel(listing)
        name = names(i);
        if ~listing(i).isdir && (endsWith(name, ".m") || name == "fileadapter.json")
            found(end + 1, :) = [relative + name, string(fullfile(folder, name))]; %#ok<AGROW>
        elseif listing(i).isdir && startsWith(name, "+") && strlength(name) > 1
            found = [found; walk(string(fullfile(folder, name)), relative + name + "/")]; %#ok<AGROW>
        end
    end
end
