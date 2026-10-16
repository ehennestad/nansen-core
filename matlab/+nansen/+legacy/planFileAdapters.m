function [entries, warnings] = planFileAdapters(sources, taken)
%planFileAdapters The file adapter documents of NANSEN dev file adapter files, without writing anything
%
%   [entries, warnings] = nansen.legacy.planFileAdapters(sources) takes a
%   cell row of structs with file (its path with its package folders, such
%   as code/+RatNav/+fileadapter/SpeedTrace.m) and text: dev's +fileadapter
%   files. A class that subclasses nansen.dataio.FileAdapter, and a folder
%   with fileadapter.json (dev's function-based adapter, with read.m and
%   write.m), each give an entry with document (its nansen.fileAdapter
%   document: id legacy.<name in snake case>, made unique against taken and
%   the others, with legacyFileAdapter), name (dev's name of it, which
%   dev's variables give as their FileAdapter) and files (a cell of structs
%   with path, under the project's matlab/ folder in the same packages,
%   and text). A class on one of dev's own adapters (its ImageStack,
%   RoiGroup, ...) also has base (that adapter's class) and reads (per row
%   an extension and the adapter here that reads such a file as the class
%   does, when the class has no readData or writeData of its own; else
%   none). A file that is not a file adapter is named in warnings. As
%   Python's nansen.legacyadapters.plan.
    arguments
        sources (1,:) cell
        taken (1,:) string = strings(1, 0)
    end
    entries = cell(1, 0);
    warnings = cell(1, 0);
    ids = taken;
    paths = strings(1, numel(sources));
    texts = strings(1, numel(sources));
    for i = 1:numel(sources)
        paths(i) = string(sources{i}.file);
        texts(i) = string(sources{i}.text);
    end
    folders = strings(1, numel(paths));
    names = paths;
    for i = 1:numel(paths)
        if contains(paths(i), "/")
            slash = strfind(paths(i), "/");
            folders(i) = extractBefore(paths(i), slash(end));
            names(i) = extractAfter(paths(i), slash(end));
        end
    end
    functional = unique(folders(names == "fileadapter.json"));
    [~, order] = sort(paths);
    for i = reshape(order, 1, [])
        folder = folders(i);
        if ismember(folder, functional)
            if names(i) ~= "fileadapter.json"
                continue   % the code of the function-based adapter of its folder
            end
            namespace = nansen.legacy.functionName(folder + "/x.m");
            namespace = regexprep(namespace, '(^|\.)x$', '');
            if namespace == ""
                where = folder;
                if where == ""
                    where = ".";
                end
                warnings{end + 1} = char(sprintf("file adapter %s: its folder is not a package (+name); left out", where)); %#ok<AGROW>
                continue
            end
            inFolder = find(folders == folder);
            [~, byName] = sort(names(inFolder));
            inFolder = inFolder(byName);
            try
                info = nansen.legacy.analyzeFileAdapter(namespace, texts(i), Files=names(inFolder));
            catch err
                warnings = withReason(warnings, err, folder);
                continue
            end
            implementation = namespace;
            legacy = struct("kind", 'function', "read", char(info.read));
            if info.write ~= ""
                legacy.write = char(info.write);
            end
            name = info.title;
            packages = "+" + split(namespace, ".")';
            files = cell(1, numel(inFolder));
            for k = 1:numel(inFolder)
                files{k} = struct("path", strjoin([packages, names(inFolder(k))], "/"), "text", texts(inFolder(k)));
            end
        else
            if ~endsWith(names(i), ".m")
                continue
            end
            implementation = nansen.legacy.functionName(paths(i));
            parts = reshape(split(implementation, "."), 1, []);
            try
                info = nansen.legacy.analyzeFileAdapter(parts(end), texts(i));
            catch err
                warnings = withReason(warnings, err, paths(i));
                continue
            end
            legacy = struct("kind", 'class');
            if isfield(info, "base")   % dev's class reads and writes with the adapter here of each file type
                legacy.base = char(info.base);
                legacy.builtIn = cell(1, size(info.builtIn, 1));
                for k = 1:size(info.builtIn, 1)
                    legacy.builtIn{k} = struct("extension", char(info.builtIn(k, 1)), "fileAdapter", char(info.builtIn(k, 2)));
                end
            end
            name = parts(end);
            files = {struct("path", strjoin(["+" + parts(1:end - 1), parts(end) + ".m"], "/"), "text", texts(i))};
        end
        base = "legacy." + snakeOf(name);
        id = base;
        number = 2;
        while ismember(id, ids)
            id = base + "_" + number;
            number = number + 1;
        end
        ids(end + 1) = id; %#ok<AGROW>
        entry = nansen.internal.schemaEntry("nansen.fileAdapter");
        document = struct("schemaType", 'nansen.fileAdapter', "schemaVersion", char(entry.version), "id", char(id), ...
            "version", '1.0.0', "title", char(info.title));
        if info.description ~= ""
            document.description = char(info.description);
        end
        if ~isempty(info.extensions)
            document.extensions = cellstr(info.extensions);
        end
        if info.dataType ~= ""
            document.dataType = char(info.dataType);
        end
        document.implementations = struct("matlab", char(implementation));
        document.legacyFileAdapter = legacy;
        nansen.checkDocument(document, ExpectedType="nansen.fileAdapter");
        entry = struct("document", document, "name", string(name), "files", {files});
        if isfield(info, "base")
            entry.base = string(info.base);
            entry.reads = strings(0, 2);   % its own readData or writeData reads and writes its files
            if ~info.overrides
                entry.reads = info.builtIn;
            end
        end
        entries{end + 1} = entry; %#ok<AGROW>
    end
end

function warnings = withReason(warnings, err, where)
    % A file that is not a file adapter: why, in the warnings
    if ~isa(err, "nansen.NansenError")
        rethrow(err)
    end
    warnings{end + 1} = char(sprintf("file adapter %s: %s; left out", where, extractAfter(string(err.message), "] ")));
end

function text = snakeOf(name)
    text = regexprep(char(name), '([A-Z]+)([A-Z][a-z])', '$1_$2');
    text = lower(regexprep(text, '([a-z0-9])([A-Z])', '$1_$2'));
    text = regexprep(regexprep(text, '_+', '_'), '^_+|_+$', '');
    if isempty(text)
        text = 'method';
    end
    text = string(text);
end
