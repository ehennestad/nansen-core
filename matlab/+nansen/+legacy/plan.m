function out = plan(export)
%plan Work out every document of the project made from a legacy export, without writing anything
%
%   The export must be checked already (nansen.legacy.convert does that).
%   plan has fields name, title, description, dataset, fragments,
%   tables, dataVariables and warnings; see nansen.legacy.convert.
    warnings = {};
    info = nansen.internal.getField(export, "project", struct());
    [dataset, levels, warnings] = buildDataset(export, warnings);
    [variables, dataset, warnings] = buildDataVariables(export, dataset, levels, warnings);
    [fragments, tables, warnings] = buildTables(export, dataset, warnings);
    shortName = textOf(info, "shortName");
    longName = textOf(info, "name");
    source = shortName;
    if source == ""
        source = longName;
    end
    if source == ""
        source = "imported";
    end
    name = identifier(source, "p", false);
    title = longName;
    if title == ""
        title = name;
    end
    out = struct("name", name, "title", title, "description", textOf(info, "description"), ...
        "dataset", dataset, "fragments", {fragments}, "tables", {tables}, "dataVariables", {variables}, ...
        "warnings", {warnings});
end

% -- data locations ------------------------------------------------------------------------

function [dataset, entityLevels, warnings] = buildDataset(export, warnings)
    defNames = strings(1, 0);
    defs = {};
    locations = {};
    entityLevels = struct();
    used = strings(1, 0);
    for item = nansen.internal.asCellOfStructs(nansen.internal.getField(export, "dataLocations", []))
        location = item{1};
        name = textOf(location, "name");
        [id, used] = uniqueName(identifier(name, "location", true), used);
        roots = {};
        rootItems = nansen.internal.asCellOfStructs(nansen.internal.getField(location, "rootPaths", []));
        for index = 1:numel(rootItems)
            root = rootItems{index};
            if textOf(root, "value") == ""
                continue
            end
            entry = struct("identifier", char(rootIdentifier(textOf(root, "key"), index, roots)), ...
                "path", char(textOf(root, "value")));
            if textOf(root, "diskName") ~= ""
                entry.volumeName = char(textOf(root, "diskName"));
            end
            roots{end + 1} = entry; %#ok<AGROW>
        end
        if isempty(roots)
            warnings{end + 1} = sprintf("data location '%s': no root path, left out", name); %#ok<AGROW>
            continue
        end
        [layout, byType] = buildLayout(nansen.internal.asCellOfStructs(nansen.internal.getField(location, "subfolders", [])));
        if ~isfield(byType, "session")
            warnings{end + 1} = sprintf("data location '%s': no folder levels, left out", name); %#ok<AGROW>
            continue
        end
        [mapping, defNames, defs, warnings] = buildMapping(location, layout, byType, defNames, defs, warnings);
        switch lower(textOf(location, "type", "recorded"))
            case "processed"
                category = "processed"; access = "readwrite";
            case "curated"
                category = "derived"; access = "readwrite";
            case "temporary"
                category = "temporary"; access = "readwrite";
            otherwise
                category = "raw"; access = "read";
        end
        displayName = name;
        if displayName == ""
            displayName = id;
        end
        source = struct("rootStoragePaths", {roots}, "entityLayout", {layout}, "metadataMapping", {mapping});
        locations{end + 1} = struct("identifier", char(id), "displayName", char(displayName), ...
            "dataCategory", char(category), "access", char(access), "sourceType", 'filesystem', ...
            "filesystemSource", source); %#ok<AGROW>
        entityLevels.(id) = byType;
    end
    hasSubject = ismember("subject_id", defNames);
    entityTypes = {};
    if hasSubject
        entityTypes{end + 1} = struct("name", 'subject', "identifierRef", 'subject_id');
    end
    entityTypes{end + 1} = struct("name", 'session', "identifierRef", 'session_id');
    if ~ismember("session_id", defNames)
        defNames(end + 1) = "session_id";
        defs{end + 1} = definition("session_id", "string", "session");
    end
    order = ["subject_id", "session_id", "session_date", "session_time"];
    ordered = [order(ismember(order, defNames)), defNames(~ismember(defNames, order))];
    definitions = struct();
    for field = ordered
        definitions.(field) = defs{find(defNames == field, 1)};
    end
    if ~hasSubject
        % Without subject identity, a subject level is structural.
        for i = 1:numel(locations)
            layout = locations{i}.filesystemSource.entityLayout;
            for k = 1:numel(layout)
                if isfield(layout{k}, "entityType") && layout{k}.entityType == "subject"
                    layout{k} = rmfield(layout{k}, "entityType");
                end
            end
            locations{i}.filesystemSource.entityLayout = layout;
        end
        for id = reshape(string(fieldnames(entityLevels)), 1, [])
            if isfield(entityLevels.(id), "subject")
                entityLevels.(id) = rmfield(entityLevels.(id), "subject");
            end
        end
    end
    dataset = struct("schemaVersion", '0.1.0', "entityTypes", {entityTypes}, ...
        "metadataDefinitions", definitions, "dataLocations", {locations});
end

function [layout, byType] = buildLayout(subfolders)
    layout = {};
    byType = struct();
    names = strings(1, 0);
    for index = 1:numel(subfolders)
        folder = subfolders{index};
        switch lower(textOf(folder, "type"))
            case "subject"
                levelName = "subjects"; entityType = "subject";
            case "session"
                levelName = "sessions"; entityType = "session";
            case "date"
                levelName = "dates"; entityType = "";
            otherwise
                levelName = "level" + index; entityType = "";
        end
        if entityType ~= "" && isfield(byType, entityType)
            entityType = "";   % a second level of the same type is structural
        end
        if ismember(levelName, names)
            levelName = levelName + index;
        end
        names(end + 1) = levelName; %#ok<AGROW>
        level = struct("name", char(levelName));
        if entityType ~= ""
            level.entityType = char(entityType);
            byType.(entityType) = char(levelName);
        end
        isFolder = nansen.internal.getField(folder, "isFolder", true);
        if islogical(isFolder) && isscalar(isFolder) && ~isFolder
            level.fileSystemType = 'file';
        end
        expression = textOf(folder, "expression");
        if expression == ""
            expression = ".";
        end
        level.matchPattern = char(expression);
        excludes = {'^\.'};
        for ignored = nansen.internal.asCellstr(nansen.internal.getField(folder, "ignoreList", []))
            if ~isempty(ignored{1})
                excludes{end + 1} = char(regexEscape(ignored{1})); %#ok<AGROW>
            end
        end
        level.excludePatterns = excludes;
        layout{end + 1} = level; %#ok<AGROW>
    end
    if ~isempty(layout) && ~isfield(byType, "session")
        % In dev, sessions are the deepest folders, whatever their level is called.
        last = layout{end};
        if isfield(last, "entityType")
            byType = rmfield(byType, last.entityType);
        end
        last.entityType = 'session';
        layout{end} = last;
        byType.session = last.name;
    end
end

function [mapping, defNames, defs, warnings] = buildMapping(location, layout, byType, defNames, defs, warnings)
    name = textOf(location, "name");
    mapping = {};
    for item = nansen.internal.asCellOfStructs(nansen.internal.getField(location, "metadata", []))
        rule = item{1};
        variable = textOf(rule, "variableName");
        switch variable
            case "Subject ID"
                field = "subject_id"; dataType = "string"; entity = "subject";
            case "Session ID"
                field = "session_id"; dataType = "string"; entity = "session";
            case "Experiment Date"
                field = "session_date"; dataType = "date"; entity = "session";
            case "Experiment Time"
                field = "session_time"; dataType = "time"; entity = "session";
            otherwise
                field = identifier(variable, "field", true); dataType = "string"; entity = "session";
        end
        where = sprintf("data location '%s', %s", name, variable);
        [extraction, warnings] = buildExtraction(rule, layout, where, warnings);
        if isempty(extraction)
            continue
        end
        if textOf(rule, "format") ~= "" && ismember(dataType, ["date", "time"])
            extraction.valueFormat = char(textOf(rule, "format"));
        end
        if ~ismember(field, defNames)
            defNames(end + 1) = field; %#ok<AGROW>
            defs{end + 1} = definition(field, dataType, entity); %#ok<AGROW>
        end
        mapping{end + 1} = struct("metadataRef", char(field), "extraction", extraction); %#ok<AGROW>
    end
    pairs = ["subject", "subject_id"; "session", "session_id"];
    for p = 1:2
        entity = pairs(p, 1);
        field = pairs(p, 2);
        % dev reads an id from the whole folder name when no rule says otherwise
        refs = string(cellfun(@(m) m.metadataRef, mapping, UniformOutput=false));
        if isfield(byType, entity) && ~ismember(field, refs)
            mapping{end + 1} = struct("metadataRef", char(field), "extraction", ...
                struct("method", 'substring', "pattern", ':', "entityLayoutLevel", byType.(entity))); %#ok<AGROW>
            if ~ismember(field, defNames)
                defNames(end + 1) = field; %#ok<AGROW>
                defs{end + 1} = definition(field, "string", entity); %#ok<AGROW>
            end
        end
    end
end

function [extraction, warnings] = buildExtraction(rule, layout, where, warnings)
    extraction = [];
    mode = lower(textOf(rule, "mode"));
    if mode == ""
        mode = "ind";
    end
    if mode == "func"
        functionName = textOf(rule, "functionName");
        if functionName == ""
            return
        end
        parts = split(functionName, ".");
        key = identifier(parts(end), "extractor", false);
        warnings{end + 1} = sprintf("%s: read by the function %s; register an extractor named '%s'", ...
            where, functionName, key);
        extraction = struct("method", 'function', "extractorFunction", char(key));
        return
    end
    levels = nansen.internal.getField(rule, "subfolderLevel", []);
    pattern = textOf(rule, "input");
    if isempty(levels) || pattern == ""
        return
    end
    if numel(levels) > 1
        warnings{end + 1} = sprintf("%s: combines several folder levels, which has no DSM rule; left out", where);
        return
    end
    index = double(levels(1));
    if index < 1 || index > numel(layout)
        warnings{end + 1} = sprintf("%s: folder level %d does not exist; left out", where, index);
        return
    end
    level = layout{index}.name;
    switch mode
        case "ind"
            sliced = nansen.legacy.indexToSlice(pattern);
            if ismissing(sliced)
                warnings{end + 1} = sprintf("%s: the index expression '%s' has no slice form; left out", where, pattern);
                return
            end
            extraction = struct("method", 'substring', "pattern", char(sliced), "entityLayoutLevel", level);
        case "expr"
            % dev takes the whole match; DSM takes the first group when there is one
            if ~isempty(regexp(pattern, '(?<!\\)\((?!\?)', "once"))
                pattern = "(" + pattern + ")";
            end
            extraction = struct("method", 'regex', "pattern", char(pattern), "entityLayoutLevel", level);
        otherwise
            warnings{end + 1} = sprintf("%s: unknown detection mode '%s'; left out", where, mode);
    end
end

function d = definition(field, dataType, entity)
    d = struct("name", char(field), "dataType", char(dataType), "ofEntity", char(entity));
end

% -- data variables ----------------------------------------------------------------------

function [variables, dataset, warnings] = buildDataVariables(export, dataset, levels, warnings)
    variables = {};
    names = strings(1, 0);
    displayNames = string(cellfun(@(l) l.displayName, dataset.dataLocations, UniformOutput=false));
    for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(export, "variables", []))
        item = entry{1};
        isInternal = nansen.internal.getField(item, "isInternal", false);
        if islogical(isInternal) && isscalar(isInternal) && isInternal
            continue
        end
        legacyName = textOf(item, "name");
        index = find(displayNames == textOf(item, "dataLocation"), 1);
        if isempty(index)
            warnings{end + 1} = sprintf("variable '%s': no session folders in data location '%s'; left out", ...
                legacyName, textOf(item, "dataLocation")); %#ok<AGROW>
            continue
        end
        location = dataset.dataLocations{index};
        locationId = string(location.identifier);
        fileType = textOf(item, "fileType");
        if fileType ~= "" && ~startsWith(fileType, ".")
            fileType = "." + fileType;
        end
        adapterName = textOf(item, "fileAdapter");
        switch lower(adapterName)
            case {"default", ""}
                switch lower(fileType)
                    case ".mat"
                        adapter = "mat";
                    case ".json"
                        adapter = "json";
                    case ".txt"
                        adapter = "text";
                    otherwise
                        adapter = "";
                end
            case {"matfile", "mat"}
                adapter = "mat";
            case "json"
                adapter = "json";
            case "text"
                adapter = "text";
            otherwise
                adapter = "";
        end
        if adapter == ""
            shown = adapterName;
            if shown == ""
                shown = "Default";
            end
            warnings{end + 1} = sprintf("variable '%s': no built-in file adapter for '%s' %s files; left out", ...
                legacyName, shown, fileType); %#ok<AGROW>
            continue
        end
        [name, names] = uniqueName(identifier(legacyName, "variable", false), names);
        expression = textOf(item, "fileNameExpression");
        if expression ~= ""
            if fileType ~= "" && endsWith(expression, fileType)
                base = expression;
            else
                base = expression + fileType;
            end
        else
            base = snake(legacyName) + fileType;
        end
        document = struct("schemaType", 'nansen.dataVariable', "schemaVersion", '0.1.0', "name", char(name), ...
            "entityType", 'session', "dataLocation", char(locationId));
        subfolder = replace(string(regexprep(char(textOf(item, "subfolder")), '^[/\\]+|[/\\]+$', '')), "\", "/");
        if expression ~= "" && subfolder == ""
            % Find existing files the way dev did, by the end of their name.
            sessionLevel = string(levels.(locationId).session);
            layout = location.filesystemSource.entityLayout;
            for k = 1:numel(layout)
                if string(layout{k}.name) == sessionLevel
                    if ~isfield(layout{k}, "filePatterns")
                        layout{k}.filePatterns = {};
                    end
                    layout{k}.filePatterns{end + 1} = struct("name", char(name), ...
                        "pattern", char(regexEscape(base) + "$"), "cardinality", 'one');
                end
            end
            location.filesystemSource.entityLayout = layout;
            dataset.dataLocations{index} = location;
            document.filePattern = char(name);
        end
        if subfolder ~= ""
            document.subfolder = char(subfolder);
        end
        document.fileName = char("{session_id}_" + base);
        document.fileAdapter = char(adapter);
        variables{end + 1} = document; %#ok<AGROW>
    end
end

% -- tables ------------------------------------------------------------------------------

function [fragments, tables, warnings] = buildTables(export, dataset, warnings)
    declared = string(cellfun(@(t) t.name, dataset.entityTypes, UniformOutput=false));
    attributes = string(fieldnames(dataset.metadataDefinitions))';
    fragments = {};
    tables = {};
    done = strings(1, 0);
    idColumns = struct("sessionID", "session_id", "SessionID", "session_id", ...
        "subjectID", "subject_id", "SubjectID", "subject_id");
    notesColumns = struct("Ignore", "ignore", "Description", "description");
    for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(export, "tables", []))
        table = entry{1};
        label = textOf(table, "name");
        entityType = lower(textOf(table, "entityClass"));
        isMaster = nansen.internal.getField(table, "isMaster", true);
        if islogical(isMaster) && isscalar(isMaster) && ~isMaster
            continue   % a dev "filtered" table holds a subset of the master's rows
        end
        if ~ismember(entityType, declared)
            shown = entityType;
            if shown == ""
                shown = "such";
            end
            warnings{end + 1} = sprintf("table '%s': the dataset has no %s entity type; left out", label, shown); %#ok<AGROW>
            continue
        end
        if ismember(entityType, done)
            warnings{end + 1} = sprintf("table '%s': a second master table of %ss; left out", label, entityType); %#ok<AGROW>
            continue
        end
        done(end + 1) = entityType; %#ok<AGROW>
        key = keyOf(entityType, declared);
        keyNames = string(key(:, 1))';
        derived = struct();
        if entityType == "session"
            derived = struct("Date", "session_date", "Time", "session_time");
        end
        columnNames = strings(1, 0);
        columnTypes = strings(1, 0);
        for c = nansen.internal.asCellOfStructs(table.columns)
            if ~ismember(string(c{1}.name), columnNames)
                columnNames(end + 1) = string(c{1}.name); %#ok<AGROW>
                columnTypes(end + 1) = string(c{1}.dataType); %#ok<AGROW>
            end
        end
        hasNotes = any(ismember(["Ignore", "Description"], columnNames));
        extra = {};
        renames = struct();
        taken = [keyNames, attributes, "ignore", "description"];
        for c = 1:numel(columnNames)
            column = columnNames(c);
            if isfield(idColumns, column) || isfield(notesColumns, column) ...
                    || (isfield(derived, column) && ismember(derived.(column), attributes))
                continue
            end
            newName = identifier(column, "column", false);
            if ismember(newName, taken)
                newName = newName + "_legacy";
            end
            taken(end + 1) = newName; %#ok<AGROW>
            renames.(column) = newName;
            columnEntry = struct("name", char(newName), "dataType", char(columnTypes(c)));
            if columnTypes(c) == "boolean"
                columnEntry.default = false;
            end
            extra{end + 1} = columnEntry; %#ok<AGROW>
        end
        for skipped = nansen.internal.asCellstr(nansen.internal.getField(table, "skippedColumns", []))
            warnings{end + 1} = sprintf("table '%s': column '%s' holds values with no table type; left out", ...
                label, skipped{1}); %#ok<AGROW>
        end
        fragmentIds = {};
        if hasNotes
            fragmentIds{end + 1} = 'core.notes'; %#ok<AGROW>
        end
        if ~isempty(extra)
            fragmentId = "legacy." + entityType;
            fragments{end + 1} = struct("schemaType", 'nansen.fragment', "schemaVersion", '0.1.0', ...
                "id", char(fragmentId), "version", '1.0.0', ...
                "title", char("Columns imported from the " + label + " table"), "columns", {extra}); %#ok<AGROW>
            fragmentIds{end + 1} = char(fragmentId); %#ok<AGROW>
        end
        rows = {};
        seen = strings(1, 0);
        incomplete = 0;
        renamed = string(struct2cell(renames))';
        for r = nansen.internal.asCellOfStructs(table.rows)
            legacyRow = r{1};
            row = struct();
            for column = reshape(string(fieldnames(legacyRow)), 1, [])
                value = legacyRow.(column);
                if isfield(idColumns, column)
                    row.(idColumns.(column)) = value;
                elseif isfield(notesColumns, column)
                    row.(notesColumns.(column)) = value;
                elseif isfield(renames, column)
                    row.(renames.(column)) = value;
                end
            end
            if isfield(row, "description") && ischar(row.description) && isempty(row.description)
                row.description = [];
            end
            if isfield(row, "ignore") && isempty(row.ignore)
                row.ignore = false;
            end
            identity = strings(1, numel(keyNames));
            complete = true;
            for k = 1:numel(keyNames)
                value = nansen.internal.getField(row, keyNames(k), []);
                if isempty(value)
                    complete = false;
                else
                    identity(k) = string(value);
                end
            end
            if ~complete
                incomplete = incomplete + 1;
                continue
            end
            identityText = strjoin(identity, "/");
            if ismember(identityText, seen)
                warnings{end + 1} = sprintf("table '%s': %s appears twice; kept the first", label, identityText); %#ok<AGROW>
                continue
            end
            seen(end + 1) = identityText; %#ok<AGROW>
            keep = [keyNames, "ignore", "description", renamed];
            fields = string(fieldnames(row))';
            if any(~ismember(fields, keep))
                row = rmfield(row, cellstr(fields(~ismember(fields, keep))));
            end
            rows{end + 1} = row; %#ok<AGROW>
        end
        if incomplete
            warnings{end + 1} = sprintf("table '%s': %d row(s) with no %s; left out", label, incomplete, ...
                strjoin(keyNames, " or ")); %#ok<AGROW>
        end
        title = upper(extractBefore(entityType, 2)) + extractAfter(entityType, 1) + "s";
        tables{end + 1} = struct("entityType", char(entityType), "title", char(title), "key", {key}, ...
            "fragments", {fragmentIds}, "rows", {rows}); %#ok<AGROW>
    end
    for entityType = declared(~ismember(declared, done))
        % a table to sync into, for entity types dev kept no table of
        title = upper(extractBefore(entityType, 2)) + extractAfter(entityType, 1) + "s";
        tables{end + 1} = struct("entityType", char(entityType), "title", char(title), ...
            "key", {keyOf(entityType, declared)}, "fragments", {{'core.notes'}}, "rows", {{}}); %#ok<AGROW>
    end
    if ~isempty(tables)
        [~, order] = sort(cellfun(@(t) find(declared == t.entityType, 1), tables));
        tables = tables(order);
    end
end

function key = keyOf(entityType, declared)
    if entityType == "subject"
        key = {'subject_id', 'string'};
    elseif ismember("subject", declared)
        key = {'subject_id', 'string'; 'session_id', 'string'};
    else
        key = {'session_id', 'string'};
    end
end

% -- names -------------------------------------------------------------------------------

function value = textOf(s, name, default)
    if nargin < 3
        default = "";
    end
    value = nansen.internal.getField(s, name, default);
    if isempty(value) && ~(isstring(value) && isscalar(value))
        value = string(default);
    end
    value = string(value);
end

function out = identifier(value, fallback, lower_)
    out = regexprep(char(value), '[^A-Za-z0-9]+', '_');
    out = regexprep(out, '^_+|_+$', '');
    if lower_
        out = lower(out);
    end
    if isempty(out)
        out = char(fallback);
    elseif ~isletter(out(1))
        out = [char(fallback), '_', out];
    end
    out = string(out);
end

function out = snake(value)
    % dev's file name for a variable: an underscore before each capital or digit, then lower case
    value = char(value);
    out = '';
    for i = 1:numel(value)
        c = value(i);
        if i > 1 && ((c >= 'A' && c <= 'Z') || (c >= '1' && c <= '9'))
            out = [out, '_']; %#ok<AGROW>
        end
        out = [out, c]; %#ok<AGROW>
    end
    out = string(lower(out));
end

function [name, used] = uniqueName(name, used)
    candidate = name;
    n = 2;
    while ismember(candidate, used)
        candidate = name + "_" + n;
        n = n + 1;
    end
    name = candidate;
    used(end + 1) = name;
end

function id = rootIdentifier(key, index, roots)
    if ~isempty(regexp(key, '^[A-Za-z][A-Za-z0-9_-]*$', "once"))
        id = key;
    else
        id = "root" + index;
    end
    if any(cellfun(@(r) string(r.identifier) == id, roots))
        id = "root" + index;
    end
end

function out = regexEscape(value)
    % As Python's re.escape: a backslash before each character that is special in a pattern
    out = string(regexprep(char(value), '([()\[\]{}?*+\-|^$\\.&~# \t\n\r\v\f])', '\\$1'));
end
