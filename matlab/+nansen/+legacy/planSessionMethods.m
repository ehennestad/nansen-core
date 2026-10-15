function [entries, warnings] = planSessionMethods(sources, entityType, taken)
%planSessionMethods The method documents of NANSEN dev session method files, without writing anything
%
%   [entries, warnings] = nansen.legacy.planSessionMethods(sources,
%   entityType) takes a cell row of structs with where (a label for
%   warnings), function (the file's MATLAB name, with its packages) and
%   text. Each session method gives an entry with document (its
%   nansen.method document: id legacy.<name in snake case>, made unique
%   against taken and the others; its category from the packages under
%   +sessionmethod, as dev's menus), file (where its code goes under the
%   project's matlab/ folder, in the same packages), text and function.
%   A file that is not a session method is named in warnings. As Python's
%   nansen.legacymethods.plan.
    arguments
        sources (1,:) cell
        entityType (1,1) string
        taken (1,:) string = strings(1, 0)
    end
    entries = cell(1, 0);
    warnings = cell(1, 0);
    ids = taken;
    for i = 1:numel(sources)
        source = sources{i};
        parts = reshape(split(string(source.function), "."), 1, []);
        try
            info = nansen.legacy.analyzeSessionMethod(parts(end), source.text);
        catch err
            if ~isa(err, "nansen.NansenError")
                rethrow(err)
            end
            warnings{end + 1} = char(sprintf("session method %s: %s; left out", source.where, ...
                extractAfter(string(err.message), "] "))); %#ok<AGROW>
            continue
        end
        base = "legacy." + snakeOf(parts(end));
        id = base;
        number = 2;
        while ismember(id, ids)
            id = base + "_" + number;
            number = number + 1;
        end
        ids(end + 1) = id; %#ok<AGROW>
        entry = nansen.internal.schemaEntry("nansen.method");
        document = struct("schemaType", 'nansen.method', "schemaVersion", char(entry.version), "id", char(id), ...
            "version", '1.0.0', "title", char(info.title));
        if info.description ~= ""
            document.description = char(info.description);
        end
        lowered = lower(parts(1:end - 1));
        k = find(lowered == "sessionmethod", 1, "last");
        if ~isempty(k) && k + 1 <= numel(parts) - 1   % dev's menus: the packages under +sessionmethod
            groups = arrayfun(@labelOf, parts(k + 1:end - 1), UniformOutput=false);
            document.category = char(strjoin(string(groups), "/"));
        end
        document.entityType = char(entityType);
        document.batchMode = char(info.batchMode);
        if ~info.queueable
            document.queueable = false;
        end
        document.implementations = struct("matlab", char(source.function));
        document.legacySessionMethod = struct("kind", char(info.kind));
        document.options = info.options;
        nansen.checkDocument(document, ExpectedType="nansen.method");
        file = strjoin(["+" + parts(1:end - 1), parts(end) + ".m"], "/");
        entries{end + 1} = struct("document", document, "file", file, "text", string(source.text), ...
            "function", string(source.function)); %#ok<AGROW>
    end
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

function text = labelOf(name)
    % dev's varname2label: words of a camelCase name, the first letter upper case
    text = regexprep(char(name), '([a-z0-9])([A-Z])', '$1 $2');
    text = strtrim(regexprep(strrep(text, '_', ' '), '\s+', ' '));
    if ~isempty(text)
        text(1) = upper(text(1));
    end
end
