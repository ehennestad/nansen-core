function result = importSessionMethods(project, path, entityType)
%importSessionMethods Import NANSEN dev session methods into a project, to run unchanged in MATLAB
%
%   result = nansen.legacy.importSessionMethods(project, path) imports the
%   session method of a .m file, or those of a folder and its package
%   folders (+name), such as a dev project's code/+<name>/+sessionmethod.
%   Each file is copied into the project's matlab/ folder, in the same
%   packages, and gets a method document (methods/legacy.<name>.method.nansen.json)
%   with legacySessionMethod, whose options are read from its text
%   (nansen.legacy.analyzeSessionMethod). nansen.runMethod runs it with a
%   nansen.legacy.SessionShim per entity. A relative path is in the project
%   folder. The methods run on entityType: by default session when the
%   project has sessions, else any (*).
%
%   result has methods (their summaries) and warnings (the files of a
%   folder that are not session methods). file-not-found, unsupported-file
%   (a file that is not a session method, or a folder with none),
%   method-exists (an id or file is taken; nothing is written). As Python's
%   nansen.legacymethods.import_into.
    arguments
        project (1,1) nansen.Project
        path (1,1) string
        entityType (1,1) string = ""
    end
    folder = string(project.Folder);
    if ~nansen.internal.isAbsolutePath(path)
        path = string(fullfile(folder, path));
    end
    if entityType == ""
        entityType = "*";
        if ismember("session", project.EntityTypes)
            entityType = "session";
        end
    elseif entityType ~= "*"
        project.entityType(entityType);
    end
    [sources, isFolder] = sourcesAt(path);
    if ~isFolder   % the reason a file is not a session method is the error
        parts = split(string(sources{1}.function), ".");
        nansen.legacy.analyzeSessionMethod(parts(end), sources{1}.text);
    end
    [entries, warnings] = nansen.legacy.planSessionMethods(sources, entityType);
    if isempty(entries)
        nansen.internal.throwError("unsupported-file", "%s holds no dev session methods", path)
    end
    existing = strings(1, 0);
    known = project.entityMethods();
    if ~isempty(known)
        existing = [known.Id];
    end
    clashes = strings(1, 0);
    for i = 1:numel(entries)
        id = string(entries{i}.document.id);
        if ismember(id, existing)
            clashes(end + 1) = id; %#ok<AGROW>
        end
        if isfile(fullfile(folder, "matlab", entries{i}.file))
            clashes(end + 1) = "matlab/" + entries{i}.file; %#ok<AGROW>
        end
        if isfile(fullfile(folder, "methods", id + ".method.nansen.json"))
            clashes(end + 1) = "methods/" + id + ".method.nansen.json"; %#ok<AGROW>
        end
    end
    if ~isempty(clashes)
        nansen.internal.throwError("method-exists", "the project already has %s", strjoin(unique(clashes, "stable"), ", "))
    end
    nansen.legacy.writeSessionMethods(folder, entries);
    summaries = cell(1, numel(entries));
    for i = 1:numel(entries)
        summaries{i} = project.method(string(entries{i}.document.id)).summary();
    end
    result = struct("methods", {summaries}, "warnings", {warnings});
end

function [sources, isFolder] = sourcesAt(path)
    % {where, function, text} of the .m file at path, or of each in a folder and its package folders (+name)
    isFolder = false;
    if isfile(path)
        [~, stem, extension] = fileparts(path);
        if extension ~= ".m"
            nansen.internal.throwError("unsupported-file", "%s is not a MATLAB file (.m)", path)
        end
        sources = {source(stem + extension, path)};
        return
    end
    if ~isfolder(path)
        nansen.internal.throwError("file-not-found", "no file or folder %s", path)
    end
    isFolder = true;
    found = walk(path, "");
    [~, order] = sort(found(:, 1));
    found = found(order, :);
    sources = cell(1, size(found, 1));
    for i = 1:size(found, 1)
        sources{i} = source(found(i, 1), found(i, 2));
    end
end

function found = walk(folder, relative)
    % [relative path, absolute path] of the .m files in a folder and its package folders (N-by-2 string)
    found = strings(0, 2);
    listing = dir(folder);
    names = string({listing.name});
    [names, order] = sort(names);
    listing = listing(order);
    for i = 1:numel(listing)
        name = names(i);
        if ~listing(i).isdir && endsWith(name, ".m")
            found(end + 1, :) = [relative + name, string(fullfile(folder, name))]; %#ok<AGROW>
        elseif listing(i).isdir && startsWith(name, "+") && strlength(name) > 1
            found = [found; walk(string(fullfile(folder, name)), relative + name + "/")]; %#ok<AGROW>
        end
    end
end

function item = source(where, path)
    item = struct("where", string(where), "function", nansen.legacy.functionName(path), ...
        "text", string(nansen.internal.readText(path)));
end
