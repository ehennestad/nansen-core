function export = exportProject(folder, options)
%exportProject Read a NANSEN dev project folder into a nansen.legacyExport struct
%
%   export = nansen.legacy.exportProject(folder) reads, without needing the
%   dev code on the path:
%
%     project.nansen.json                          Properties.Name, ShortName, Description
%     configurations/datalocation_settings.mat     data locations (Data)
%     configurations/filepath_settings.mat         variables (Data)
%     metadata/tables/*.mat                        MetaTables (MetaTableEntries and catalog fields)
%     configurations/pipeline_settings.mat         pipelines (Data)
%     configurations/custom_options/*.mat          option presets users made, by function (OptionsEntries
%                                                  of Type Custom, with their Options), and DefaultOptionsName
%     code/+<package>/+sessionmethod/**/*.m         the project's own session methods, with their text
%     code/+<package>/+fileadapter/**               the project's own file adapters (.m files, and the
%                                                  fileadapter.json of function-based ones), with their text
%     code/+<package>/+tablevariable/**/*.m         the project's own table variables, with their text
%     metadata/tables/metatable_catalog.mat        the table of each kind dev opens first (IsDefault)
%     metadata/tables/metatable_column_settings.*  the tables' column layout (.json, or the .mat of older
%                                                  versions): label, shown, width and place of each column
%
%   and, from the user's preferences (dev's nansen.prefdir: UserFolder=,
%   by default prefdir/Nansen/default):
%
%     custom_options/*.mat                         option presets of dev's own methods (NoRMCorre, Quicky, ...)
%     projects/<name>/task_list.mat                the task list: queued tasks (method, sessions, options,
%                                                  preset, created, comment) and the history (method,
%                                                  sessions, status, finished)
%     settings/task_list.mat                       the task list of older versions, one for all the user's
%                                                  projects (dev's nansen.localpath('TaskList')): read as the
%                                                  other, after it, less the tasks that one has too
%     settings/nansen_app_settings.mat             nansen.App's preferences (settings)
%
%   Table values become JSON values: text, numbers, logicals and dates.
%   Columns of other types (structs, objects, several columns per variable)
%   are listed in skippedColumns. Empty text and NaN/NaT are null. The notes
%   of a Notebook column (dev's nansen.notes.Note structs) are the table's
%   notes, each with the index of its row, and its Progress column (the
%   pipeline of each session) is the table's progress: per row, the
%   pipeline's name and the tasks of it dev marked finished, with the date.
%   Options become JSON values where they have one (structs, text, numbers,
%   logicals, cells of text); those that have not are named (skippedOptions).
%   A task's sessions are its entityId, or the sessionID of the sessions it
%   was given, or its name (dev names a task of one session by its id).
%   dev's session objects in a task, which do not load without dev, load
%   through stand-ins of dev's session classes that keep their ids, so a
%   task of several sessions (Multisession) names them too.
%
%   exportProject(folder, File=path) also writes the export as JSON, which
%   the Python command `nansen import-legacy` converts as well.
    arguments
        folder (1,1) string
        options.File (1,1) string = ""
        options.UserFolder (1,1) string = string(fullfile(prefdir, "Nansen", "default"))
    end
    if ~isfolder(folder)
        nansen.internal.throwError("file-not-found", "no folder %s", folder)
    end
    export = struct("schemaType", 'nansen.legacyExport', "schemaVersion", '0.1.0', "source", char(folder));
    export.project = readProjectInfo(folder);
    export.dataLocations = readDataLocations(fullfile(folder, "configurations", "datalocation_settings.mat"));
    export.variables = readVariables(fullfile(folder, "configurations", "filepath_settings.mat"));
    [export.tables, classes] = readTables(fullfile(folder, "metadata", "tables"));
    export.pipelines = readPipelines(fullfile(folder, "configurations", "pipeline_settings.mat"));
    export.presets = [readPresets(fullfile(folder, "configurations", "custom_options")), ...
        readPresets(fullfile(options.UserFolder, "custom_options"))];
    export.sessionMethods = readSessionMethods(folder);
    export.fileAdapters = readFileAdapters(folder);
    export.tableVariables = readTableVariables(folder);
    columnSettings = readColumnSettings(fullfile(folder, "metadata", "tables"));
    if ~isempty(columnSettings)
        export.columnSettings = columnSettings;
    end
    % the project's task list, and the one older versions of dev kept for all the user's projects
    taskLists = taskListPath(folder, export.project, options.UserFolder);
    older = string(fullfile(options.UserFolder, "settings", "task_list.mat"));
    if isfile(older)
        taskLists(end + 1) = older;
    end
    if ~isempty(taskLists)
        export.tasks = readTaskLists(taskLists, classes);
    end
    settings = readSettings(fullfile(options.UserFolder, "settings", "nansen_app_settings.mat"));
    if ~isempty(settings)
        export.settings = settings;
    end
    export = nansen.checkDocument(nansen.internal.jsonRoundTrip(export), ExpectedType="nansen.legacyExport", ...
        Source="legacy export");
    if options.File ~= ""
        nansen.internal.writeJson(options.File, export)
    end
end

function info = readProjectInfo(folder)
    [~, name] = fileparts(folder);
    info = struct("name", char(name));
    path = fullfile(folder, "project.nansen.json");
    if ~isfile(path)
        return
    end
    properties = nansen.internal.getField(nansen.internal.readJson(path), "Properties", struct());
    for pair = ["Name", "name"; "ShortName", "shortName"; "Description", "description"]'
        value = nansen.internal.getField(properties, pair(1), "");
        if (ischar(value) || isstring(value)) && strlength(string(value)) > 0
            info.(pair(2)) = char(value);
        end
    end
end

function locations = readDataLocations(path)
    locations = {};
    items = loadData(path);
    for i = 1:numel(items)
        item = items(i);
        location = struct("name", textOf(item, "Name"), "type", textOf(getOr(item, "Type", "recorded")));
        roots = {};
        rootPaths = getOr(item, "RootPath", struct([]));
        if iscell(rootPaths)
            rootPaths = struct("Value", rootPaths);
        end
        for k = 1:numel(rootPaths)
            root = struct("key", textOf(rootPaths(k), "Key"), "value", textOf(rootPaths(k), "Value"));
            if textOf(rootPaths(k), "DiskName") ~= ""
                root.diskName = textOf(rootPaths(k), "DiskName");
            end
            if root.value ~= ""
                roots{end + 1} = root; %#ok<AGROW>
            end
        end
        location.rootPaths = roots;
        subfolders = {};
        structure = getOr(item, "SubfolderStructure", struct([]));
        for k = 1:numel(structure)
            level = structure(k);
            isFolder = getOr(level, "IsFolder", true);
            if isempty(isFolder)
                isFolder = true;
            end
            subfolders{end + 1} = struct("name", textOf(level, "Name"), "type", textOf(level, "Type"), ...
                "expression", textOf(level, "Expression"), ...
                "ignoreList", {textList(getOr(level, "IgnoreList", {}))}, "isFolder", logical(isFolder(1))); %#ok<AGROW>
        end
        location.subfolders = subfolders;
        rules = {};
        definitions = getOr(item, "MetaDataDef", struct([]));
        for k = 1:numel(definitions)
            definition = definitions(k);
            mode = lower(textOf(definition, "StringDetectMode"));
            if ~ismember(mode, ["ind", "expr", "func"])
                mode = 'ind';
            end
            levels = double(getOr(definition, "SubfolderLevel", []));
            rule = struct("variableName", textOf(definition, "VariableName"), ...
                "subfolderLevel", {num2cell(reshape(levels(levels >= 1), 1, []))}, "mode", char(mode), ...
                "input", textOf(definition, "StringDetectInput"), "format", textOf(definition, "StringFormat"), ...
                "separator", textOf(definition, "Separator"), "functionName", textOf(definition, "FunctionName"));
            rules{end + 1} = rule; %#ok<AGROW>
        end
        location.metadata = rules;
        locations{end + 1} = location; %#ok<AGROW>
    end
end

function variables = readVariables(path)
    variables = {};
    items = loadData(path);
    for i = 1:numel(items)
        item = items(i);
        isInternal = getOr(item, "IsInternal", false);
        variables{end + 1} = struct("name", textOf(item, "VariableName"), ...
            "dataLocation", textOf(item, "DataLocation"), "subfolder", textOf(item, "Subfolder"), ...
            "fileNameExpression", textOf(item, "FileNameExpression"), "fileType", textOf(item, "FileType"), ...
            "fileAdapter", textOf(item, "FileAdapter"), "dataType", textOf(item, "DataType"), ...
            "isInternal", ~isempty(isInternal) && logical(isInternal(1))); %#ok<AGROW>
    end
end

function [tables, classes] = readTables(folder)
    % The MetaTables, with whether dev opened each first (the catalog's IsDefault), and the classes of the objects
    % their rows are (MetaTableClass, ItemClassName)
    tables = {};
    classes = strings(1, 0);
    catalog = readCatalog(folder);
    listing = dir(fullfile(folder, "*.mat"));
    for name = sort(string({listing.name}))
        if ismember(name, ["metatable_catalog.mat", "metatable_column_settings.mat"])
            continue
        end
        S = load(fullfile(folder, name));
        if ~isfield(S, "MetaTableEntries") || ~istable(S.MetaTableEntries)
            continue
        end
        className = textOf(S, "MetaTableClass");
        for given = string({className, textOf(S, "ItemClassName")})
            if given ~= "" && ~ismember(given, classes)
                classes(end + 1) = given; %#ok<AGROW>
            end
        end
        parts = split(string(className), ".");
        entries = S.MetaTableEntries;
        [columns, skipped, rows, notes, progress] = readEntries(entries);
        label = textOf(S, "MetaTableName");
        if label == ""
            [~, label] = fileparts(name);
            label = char(label);
        end
        isMaster = getOr(S, "IsMaster", true);
        table_ = struct("name", label, "entityClass", char(lower(parts(end))), ...
            "isMaster", ~isempty(isMaster) && logical(isMaster(1)), "columns", {columns}, ...
            "skippedColumns", {cellstr(skipped)}, "notes", {notes}, "progress", {progress}, "rows", {rows});
        isDefault = defaultOf(catalog, name, label);
        if ~isempty(isDefault)
            table_.isDefault = isDefault;
        end
        tables{end + 1} = table_; %#ok<AGROW>
    end
end

function catalog = readCatalog(folder)
    % dev's MetaTableCatalog (metatable_catalog.mat's metaTableCatalog, a table): per MetaTable its FileName,
    % MetaTableName and IsDefault; [] when there is none
    catalog = [];
    path = fullfile(folder, "metatable_catalog.mat");
    if ~isfile(path)
        return
    end
    S = loadQuietly(path);
    if isfield(S, "metaTableCatalog") && istable(S.metaTableCatalog)
        catalog = S.metaTableCatalog;
    end
end

function isDefault = defaultOf(catalog, fileName, label)
    % The catalog's IsDefault of a MetaTable (the one of its class dev opens first), found by its file name or else
    % its name; [] when the catalog does not say
    isDefault = [];
    if isempty(catalog)
        return
    end
    names = string(catalog.Properties.VariableNames);
    if ~ismember("IsDefault", names)
        return
    end
    at = [];
    if ismember("FileName", names)
        at = find(string(catalog.FileName) == string(fileName), 1);
    end
    if isempty(at) && ismember("MetaTableName", names)
        at = find(string(catalog.MetaTableName) == string(label), 1);
    end
    if isempty(at)
        return
    end
    value = catalog.IsDefault(at);
    if iscell(value)
        value = value{1};
    end
    if (islogical(value) || isnumeric(value)) && isscalar(value)
        isDefault = logical(value);
    end
end

function settings = readColumnSettings(folder)
    % dev's column layout of its tables (its Project's MetatableColumnSettings: metatable_column_settings.json, or the
    % .mat of older versions): per table variable its label, whether it is shown, its width and its place
    settings = {};
    items = {};
    if isfile(fullfile(folder, "metatable_column_settings.json"))
        try
            items = jsondecode(nansen.internal.readText(fullfile(folder, "metatable_column_settings.json")));
        catch
            items = {};
        end
    elseif isfile(fullfile(folder, "metatable_column_settings.mat"))
        items = getOr(loadQuietly(fullfile(folder, "metatable_column_settings.mat")), "MetatableColumnSettings", {});
    end
    if isstruct(items)
        items = num2cell(reshape(items, 1, []));
    elseif ~iscell(items)
        items = {};
    end
    for i = 1:numel(items)
        item = items{i};
        if ~(isstruct(item) && isscalar(item)) || isempty(textOf(item, "VariableName"))
            continue
        end
        setting = struct("variable", textOf(item, "VariableName"));
        if ~isempty(textOf(item, "ColumnLabel"))
            setting.label = textOf(item, "ColumnLabel");
        end
        show = getOr(item, "ShowColumn", []);
        if (islogical(show) || isnumeric(show)) && isscalar(show)
            setting.show = logical(show);
        end
        for pair = ["ColumnWidth", "width"; "ColumnOrder", "order"]'
            value = getOr(item, pair(1), []);
            if isnumeric(value) && isscalar(value) && isfinite(value)
                setting.(pair(2)) = double(value);
            end
        end
        settings{end + 1} = setting; %#ok<AGROW>
    end
end

function variables = readTableVariables(folder)
    % The .m files of the project's table variable packages (code/+<package>/+tablevariable, with a package per entity
    % type: +session, +subject), in order of their paths, with their text
    variables = {};
    files = strings(0, 1);
    for package = reshape(dir(fullfile(folder, "code", "+*")), 1, [])
        root = fullfile(folder, "code", package.name, "+tablevariable");
        if package.isdir && isfolder(root)
            files = [files; packageFiles(root, "code/" + string(package.name) + "/+tablevariable/")]; %#ok<AGROW>
        end
    end
    for file = reshape(sort(files), 1, [])
        [~, name] = fileparts(file);
        if isvarname(char(name))
            variables{end + 1} = struct("file", char(file), "text", nansen.internal.readText(fullfile(folder, file))); %#ok<AGROW>
        end
    end
end

function [columns, skipped, rows, notes, progress] = readEntries(entries)
    names = string(entries.Properties.VariableNames);
    columns = {};
    skipped = strings(1, 0);
    values = {};
    kept = strings(1, 0);
    notes = {};
    progress = {};
    for name = names
        if name == "Progress"
            [isProgress, columnProgress] = progressOf(entries.(name));
            if isProgress
                progress = columnProgress;
                continue
            end
        end
        [isNotebook, columnNotes] = notebookNotes(name, entries.(name));
        if isNotebook
            notes = [notes, columnNotes]; %#ok<AGROW>
            continue
        end
        [dataType, column] = columnValues(entries.(name));
        if dataType == ""
            skipped(end + 1) = name; %#ok<AGROW>
            continue
        end
        columns{end + 1} = struct("name", char(name), "dataType", char(dataType)); %#ok<AGROW>
        kept(end + 1) = name; %#ok<AGROW>
        values{end + 1} = column; %#ok<AGROW>
    end
    rows = cell(1, height(entries));
    for r = 1:height(entries)
        row = struct();
        for c = 1:numel(kept)
            row.(kept(c)) = values{c}{r};
        end
        rows{r} = row;
    end
end

function [dataType, column] = columnValues(value)
    % The column's table type and its values as JSON values, or "" when it has no table type
    dataType = "";
    column = {};
    if size(value, 2) ~= 1 && ~(ischar(value) && size(value, 1) == 1)
        return
    end
    n = size(value, 1);
    if islogical(value)
        dataType = "boolean";
        column = num2cell(value);
    elseif isinteger(value)
        dataType = "integer";
        column = num2cell(double(value));
    elseif isnumeric(value) && isreal(value)
        dataType = "number";
        column = arrayfun(@numberOrNull, double(value), UniformOutput=false);
    elseif isstring(value) || iscategorical(value)
        dataType = "string";
        column = arrayfun(@(v) textOrNull(string(v)), value, UniformOutput=false);
    elseif isdatetime(value)
        times = value(~isnat(value));
        if all(timeofday(times) == duration(0, 0, 0))
            dataType = "date";
            format = 'yyyy-MM-dd';
        else
            dataType = "datetime";
            format = 'yyyy-MM-dd''T''HH:mm:ss.SSS';
        end
        column = arrayfun(@(v) datetimeOrNull(v, format), value, UniformOutput=false);
    elseif iscell(value)
        isText = cellfun(@(v) (ischar(v) && (isrow(v) || isempty(v))) || (isstring(v) && isscalar(v)) ...
            || (isnumeric(v) && isempty(v)), value);
        isFlag = cellfun(@(v) islogical(v) && isscalar(v), value);
        isNumber = cellfun(@(v) (isnumeric(v) && isreal(v) && isscalar(v)) || (isnumeric(v) && isempty(v)), value);
        if all(isText) && ~all(cellfun(@(v) isnumeric(v), value))
            dataType = "string";
            column = cellfun(@(v) textOrNull(string(v)), value, UniformOutput=false);
        elseif all(isFlag)
            dataType = "boolean";
            column = value;
        elseif all(isNumber)
            dataType = "number";
            column = cellfun(@numberOrNull, value, UniformOutput=false);
        end
    end
    if dataType ~= ""
        column = reshape(column, n, 1);
    end
end

function [isNotebook, notes] = notebookNotes(name, value)
    % A Notebook column holds, per row, a struct array of notes (often wrapped in a cell)
    notes = {};
    if ~iscell(value) && ~isstruct(value)
        isNotebook = false;
        return
    end
    cells = value;
    if isstruct(value)
        cells = num2cell(value);
    end
    noteFields = ["Title", "Text", "Type", "DateTime"];
    shaped = cellfun(@(v) isempty(v) || (isstruct(unwrap(v)) && any(isfield(unwrap(v), noteFields))), cells);
    hasNotes = any(cellfun(@(v) ~isempty(v) && isstruct(unwrap(v)) && ~isempty(unwrap(v)), cells));
    isNotebook = all(shaped) && (hasNotes || name == "Notebook") && size(value, 2) == 1;
    if ~isNotebook
        return
    end
    for r = 1:numel(cells)
        items = unwrap(cells{r});
        for i = 1:numel(items)
            note = items(i);
            createdAt = [];
            stamp = getOr(note, "DateTime", NaT);
            if isdatetime(stamp) && isscalar(stamp) && ~isnat(stamp)
                createdAt = datetimeOrNull(stamp, 'yyyy-MM-dd''T''HH:mm:ss');
            end
            type = textOf(note, "Type");
            if isempty(type)
                type = 'Informal';
            end
            notes{end + 1} = struct("row", r - 1, "createdAt", createdAt, "author", textOf(note, "Author"), ...
                "type", type, "title", textOf(note, "Title"), "text", multilineText(getOr(note, "Text", ''))); %#ok<AGROW>
        end
    end
end

function value = unwrap(value)
    if iscell(value) && isscalar(value)
        value = value{1};
    end
end

function text = multilineText(value)
    % A note's text: one char row, a char matrix or a cell of lines, as one char row with line feeds
    if iscell(value)
        value = strjoin(cellfun(@(line) char(line), reshape(value, 1, []), UniformOutput=false), newline);
    elseif isstring(value)
        value = strjoin(value, newline);
    elseif ischar(value) && size(value, 1) > 1
        value = strjoin(cellstr(value), newline);
    end
    text = textOf(value);
end

function value = numberOrNull(v)
    if isempty(v) || isnan(v) || ~isfinite(v)
        value = [];
    else
        value = double(v);
    end
end

function value = textOrNull(v)
    if isempty(v) || ismissing(v) || strlength(v) == 0
        value = [];
    else
        value = char(v);
    end
end

function value = datetimeOrNull(v, format)
    if isnat(v)
        value = [];
    else
        v.TimeZone = '';
        value = char(v, format);
    end
end

function pipelines = readPipelines(path)
    % PipelineCatalog's Data: a name, tasks (TaskName, TaskFunction, OptionPresetSelection) and the session properties that assign it
    pipelines = {};
    items = loadData(path);
    for i = 1:numel(items)
        tasks = {};
        list = getOr(items(i), "PipelineTasks", struct([]));
        for t = 1:numel(list)
            if isstruct(list)
                task = struct("name", textOf(list(t), "TaskName"), "function", textOf(list(t), "TaskFunction"));
                preset = textOf(list(t), "OptionPresetSelection");
                if ~isempty(preset)
                    task.preset = preset;
                end
                tasks{end + 1} = task; %#ok<AGROW>
            end
        end
        assign = {};
        rules = getOr(items(i), "SessionProperties", struct([]));
        for r = 1:numel(rules)
            if isstruct(rules)
                assign{end + 1} = struct("variable", textOf(rules(r), "VariableName"), "mode", textOf(rules(r), "Mode"), ...
                    "expression", textOf(rules(r), "Expression")); %#ok<AGROW>
            end
        end
        pipelines{end + 1} = struct("name", textOf(items(i), "PipelineName"), "tasks", {tasks}, "assign", {assign}); %#ok<AGROW>
    end
end

function presets = readPresets(folder)
    % OptionsManager's files, one per function: the presets a user made (Type Custom), with their options, and the
    % preset the function runs with when none is chosen (DefaultOptionsName)
    presets = {};
    listing = dir(fullfile(folder, "*.mat"));
    names = sort(string({listing.name}));
    for i = 1:numel(names)
        S = loadQuietly(fullfile(folder, names(i)));
        if ~isfield(S, "OptionsEntries") || ~isstruct(S.OptionsEntries)
            continue
        end
        custom = {};
        entries = {};
        for k = 1:numel(S.OptionsEntries)
            option = S.OptionsEntries(k);
            if string(textOf(option, "Type")) ~= "Custom"
                continue
            end
            custom{end + 1} = textOf(option, "Name"); %#ok<AGROW>
            entry = struct("name", textOf(option, "Name"));
            if ~isempty(textOf(option, "Description"))
                entry.description = textOf(option, "Description");
            end
            values = getOr(option, "Options", struct());
            if ~(isstruct(values) && isscalar(values))
                values = struct();
            end
            [entry.options, unreadable] = jsonOptions(values, "");
            if ~isempty(unreadable)
                entry.skippedOptions = cellstr(unreadable);
            end
            entries{end + 1} = entry; %#ok<AGROW>
        end
        defaultName = textOf(S, "DefaultOptionsName");
        if ~isempty(custom) || ~(isempty(defaultName) || strcmpi(defaultName, 'Default'))
            functionName = char(extractBefore(names(i), strlength(names(i)) - 3));   % less .mat
            item = struct("function", functionName, "names", {custom}, "entries", {entries});
            if ~isempty(defaultName)
                item.defaultName = defaultName;
            end
            presets{end + 1} = item; %#ok<AGROW>
        end
    end
end

function [out, unreadable] = jsonOptions(options, prefix)
    % A struct of options as JSON values: the fields that have one, and the paths (a.b) of those that have not
    out = struct();
    unreadable = strings(1, 0);
    for name = reshape(string(fieldnames(options)), 1, [])
        value = options.(name);
        if isstruct(value) && isscalar(value)
            [out.(name), more] = jsonOptions(value, prefix + name + ".");
            unreadable = [unreadable, more]; %#ok<AGROW>
            continue
        end
        [ok, value] = jsonValue(value);
        if ok
            out.(name) = value;
        else
            unreadable(end + 1) = prefix + name; %#ok<AGROW>
        end
    end
end

function [ok, value] = jsonValue(value)
    % A value as JSON (text, a number or logical, a row or matrix of them, a cell of text), or ok false
    ok = true;
    if ischar(value) && (isrow(value) || isempty(value))
        value = char(value);
    elseif (isstring(value) || iscategorical(value)) && isscalar(value)
        value = textOrNull(string(value));
    elseif (isnumeric(value) && isreal(value)) || islogical(value)
        if isempty(value)
            value = [];
        elseif ~ismatrix(value)
            ok = false;
        elseif isnumeric(value)
            value = double(value);
        end
    elseif iscell(value) && (isempty(value) || iscellstr(value))
        value = reshape(cellfun(@char, value, UniformOutput=false), 1, []);
    else
        ok = false;
    end
end

function path = taskListPath(folder, info, userFolder)
    % dev's task list of the project: <user folder>/projects/<name>/task_list.mat, the name being the project's
    % package (code/+<name>), its short name or its folder's name; none (an empty string array) when there is none
    candidates = strings(1, 0);
    for package = reshape(dir(fullfile(folder, "code", "+*")), 1, [])
        if package.isdir
            candidates(end + 1) = extractAfter(string(package.name), 1); %#ok<AGROW>
        end
    end
    candidates(end + 1) = string(textOf(info, "shortName"));
    [~, name] = fileparts(folder);
    candidates(end + 1) = string(name);
    path = strings(1, 0);
    for candidate = candidates(strlength(candidates) > 0)
        if isfile(fullfile(userFolder, "projects", candidate, "task_list.mat"))
            path = string(fullfile(userFolder, "projects", candidate, "task_list.mat"));
            return
        end
    end
end

function tasks = readTaskLists(paths, classes)
    % The tasks of dev's task lists, in order: the project's, then the one older versions kept in the user's settings
    % (dev's nansen.localpath('TaskList'), for all the user's projects: the tasks of other projects' sessions are
    % named as not here when they are converted). A task of the older list that the project's has too is left out.
    % dev's session objects in the tasks load through stand-ins of dev's session classes (sessionStubs), which keep
    % their ids, so a task of several sessions names them without dev.
    stubs = sessionStubs(classes); %#ok<NASGU>   removed when this returns
    tasks = struct("queue", {{}}, "history", {{}});
    seen = strings(1, 0);
    for path = reshape(paths, 1, [])
        list = readTaskList(path);
        for kind = ["queue", "history"]
            for i = 1:numel(list.(kind))
                task = list.(kind){i};
                identity = strjoin([kind, string(task.function), strjoin(string(task.entities), ","), ...
                    string(textOf(task, "createdAt")), string(textOf(task, "finishedAt")), string(textOf(task, "status"))], char(30));
                if ismember(identity, seen)
                    continue
                end
                seen(end + 1) = identity; %#ok<AGROW>
                tasks.(kind){end + 1} = task;
            end
        end
    end
end

function cleanup = sessionStubs(classes)
    % Stand-ins of dev's session and subject classes (nansen.metadata.type.Session and Subject, and those the tables
    % name as theirs), so that dev's objects in a task list load without dev, as objects of these: each keeps only
    % the ids (sessionID, subjectID) of the object saved, and drops the rest of it. None is made of a class that is on
    % the path (dev's, when dev is). They are written to a temporary folder put on the path, which the returned
    % onCleanup removes again.
    folder = string(tempname);
    added = false;
    for name = reshape(unique(["nansen.metadata.type.Session", "nansen.metadata.type.Subject", classes], "stable"), 1, [])
        if isempty(regexp(name, '^[A-Za-z]\w*(\.[A-Za-z]\w*)*$', 'once')) || exist(name, "class") == 8
            continue
        end
        parts = reshape(split(name, "."), 1, []);
        target = folder;
        if numel(parts) > 1
            target = string(fullfile(folder, strjoin("+" + parts(1:end - 1), filesep)));
        end
        if ~isfolder(target)
            mkdir(target);
        end
        lines = [
            "classdef " + parts(end) + " < dynamicprops"
            "%" + parts(end) + " A stand-in of dev's " + name + " while nansen.legacy.exportProject reads a task list: the ids of a saved object"
            "    properties"
            "        sessionID"
            "        subjectID"
            "    end"
            "end"];
        nansen.internal.writeText(fullfile(target, parts(end) + ".m"), strjoin(lines', newline) + newline);
        added = true;
    end
    if added
        addpath(folder);
    end
    cleanup = onCleanup(@() removeStubs(folder, added));
end

function removeStubs(folder, added)
    if added
        rmpath(folder);
    end
    if isfolder(folder)
        rmdir(folder, "s");
    end
end

function tasks = readTaskList(path)
    % TaskProcessor's lists (taskListQueue, taskListHistory): what each task runs, on which sessions, and how
    tasks = struct("queue", {{}}, "history", {{}});
    S = loadQuietly(path);
    queue = getOr(S, "taskListQueue", struct([]));
    if ~isstruct(queue)
        queue = struct([]);
    end
    for i = 1:numel(queue)
        item = queue(i);
        task = struct("function", functionOf(getOr(item, "method", '')), "name", textOf(item, "name"), ...
            "entities", {entityIdsOf(item)});
        args = getOr(item, "args", {});
        if iscell(args) && numel(args) >= 2 && isstruct(args{2}) && isscalar(args{2})
            task.options = jsonOptions(args{2}, "");
        end
        if ~isempty(textOf(item, "parameters"))
            task.preset = textOf(item, "parameters");
        end
        created = stampOf(getOr(item, "timeCreated", ''));
        if created ~= ""
            task.createdAt = char(created);
        end
        if ~isempty(textOf(item, "comments"))
            task.comment = textOf(item, "comments");
        end
        tasks.queue{end + 1} = task;
    end
    history = getOr(S, "taskListHistory", struct([]));
    if ~isstruct(history)
        history = struct([]);
    end
    for i = 1:numel(history)
        item = history(i);
        task = struct("function", functionOf(getOr(item, "method", '')), "name", textOf(item, "name"), ...
            "entities", {entityIdsOf(item)}, "status", textOf(item, "status"));
        finished = stampOf(getOr(item, "timeFinished", ''));
        if finished ~= ""
            task.finishedAt = char(finished);
        end
        tasks.history{end + 1} = task;
    end
end

function name = functionOf(method)
    % The name of a task's method: func2str of its function handle
    name = '';
    if isa(method, "function_handle")
        name = func2str(method);
    elseif ischar(method) && isrow(method)
        name = method;
    end
end

function ids = entityIdsOf(item)
    % A task's sessions, by id: its entityId (set when it went into the history); else the sessionID of the sessions
    % it was given (a queued task's first argument, and a finished one's in older versions of dev, which kept it in
    % the history), which load through sessionStubs' stand-ins of dev's classes; else its name, unless it is
    % Multisession
    ids = {};
    stored = getOr(item, "entityId", {});
    if (iscellstr(stored) || isstring(stored)) && ~isempty(stored)
        ids = reshape(cellstr(stored), 1, []);
        return
    end
    args = getOr(item, "args", {});
    if iscell(args) && ~isempty(args)
        try
            sessions = args{1};
            for k = 1:numel(sessions)
                id = sessions(k).sessionID;
                if isstring(id) && isscalar(id)
                    id = char(id);
                end
                if ischar(id) && isrow(id)
                    ids{end + 1} = id; %#ok<AGROW>
                end
            end
        catch
            ids = {};   % not sessions (a finished task's options), or objects of a class that did not load
        end
    end
    name = textOf(item, "name");
    if isempty(ids) && ~isempty(name) && ~strcmp(name, 'Multisession')
        ids = {name};
    end
end

function stamp = stampOf(value)
    % A time as yyyy-MM-ddTHH:mm:ss: a datetime, or dev's text of one (yyyy.MM.dd HH:mm:ss); "" for none
    stamp = "";
    try
        if (ischar(value) || isstring(value)) && strlength(string(value)) > 0
            value = datetime(char(value), "InputFormat", "yyyy.MM.dd HH:mm:ss");
        end
        if isdatetime(value) && isscalar(value) && ~isnat(value)
            value.TimeZone = '';
            stamp = string(char(value, 'yyyy-MM-dd''T''HH:mm:ss'));
        end
    catch
        stamp = "";
    end
end

function [isProgress, progress] = progressOf(value)
    % The Progress column: per row, the struct of the pipeline dev assigned (PipelineName, TaskList), or empty
    progress = {};
    if isstruct(value)
        cells = num2cell(value);
    elseif iscell(value)
        cells = value;
    else
        isProgress = false;
        return
    end
    isProgress = size(value, 2) == 1 && all(cellfun(@(v) isempty(v) || (isstruct(v) && isfield(v, "TaskList")), cells));
    if ~isProgress
        return
    end
    for r = 1:numel(cells)
        if isempty(cells{r})
            continue
        end
        pipeline = cells{r}(1);
        tasks = {};
        list = getOr(pipeline, "TaskList", struct([]));
        if ~isstruct(list)
            list = struct([]);
        end
        for t = 1:numel(list)
            finished = getOr(list(t), "IsFinished", false);
            if isempty(finished) || ~(islogical(finished) || isnumeric(finished)) || ~finished(1)
                continue
            end
            stamp = stampOf(getOr(list(t), "DateFinished", NaT));
            finishedAt = [];
            if stamp ~= ""
                finishedAt = char(stamp);
            end
            tasks{end + 1} = struct("function", textOf(list(t), "FunctionName"), "finishedAt", finishedAt); %#ok<AGROW>
        end
        progress{end + 1} = struct("row", r - 1, "pipeline", textOf(pipeline, "PipelineName"), "tasks", {tasks}); %#ok<AGROW>
    end
end

function settings = readSettings(path)
    % nansen.App's preferences (its settings struct), as JSON values; [] when there are none
    settings = [];
    if ~isfile(path)
        return
    end
    S = loadQuietly(path);
    if isfield(S, "settings") && isstruct(S.settings) && isscalar(S.settings)
        settings = jsonOptions(S.settings, "");
    end
end

function S = loadQuietly(path)
    % A .mat file of dev's, which may hold objects of dev's classes: loaded without the warnings for those
    state = warning("off", "all");
    restore = onCleanup(@() warning(state));
    S = load(path);
    clear restore
end

function methods_ = readSessionMethods(folder)
    % The .m files of the project's session method packages (dev's Module.getObjectMethodFolder: code/+<package>/
    % +sessionmethod, and the packages in it), in order of their paths, with their text
    methods_ = {};
    files = strings(0, 1);
    for package = reshape(dir(fullfile(folder, "code", "+*")), 1, [])
        root = fullfile(folder, "code", package.name, "+sessionmethod");
        if package.isdir && isfolder(root)
            files = [files; packageFiles(root, "code/" + string(package.name) + "/+sessionmethod/")]; %#ok<AGROW>
        end
    end
    for file = reshape(sort(files), 1, [])
        methods_{end + 1} = struct("file", char(file), "text", nansen.internal.readText(fullfile(folder, file))); %#ok<AGROW>
    end
end

function adapters = readFileAdapters(folder)
    % The files of the project's file adapter packages (code/+<package>/+fileadapter, and the packages in it): the
    % .m files, and the fileadapter.json of dev's function-based adapters, in order of their paths, with their text
    adapters = {};
    files = strings(0, 1);
    for package = reshape(dir(fullfile(folder, "code", "+*")), 1, [])
        root = fullfile(folder, "code", package.name, "+fileadapter");
        if package.isdir && isfolder(root)
            files = [files; packageFiles(root, "code/" + string(package.name) + "/+fileadapter/", true)]; %#ok<AGROW>
        end
    end
    for file = reshape(sort(files), 1, [])
        adapters{end + 1} = struct("file", char(file), "text", nansen.internal.readText(fullfile(folder, file))); %#ok<AGROW>
    end
end

function files = packageFiles(folder, relative, definitions)
    % The relative paths of the .m files in a folder and its package folders (+name); with definitions, also their
    % fileadapter.json files
    if nargin < 3
        definitions = false;
    end
    files = strings(0, 1);
    for item = reshape(dir(folder), 1, [])
        name = string(item.name);
        if ~item.isdir && (endsWith(name, ".m") || (definitions && name == "fileadapter.json"))
            files(end + 1, 1) = relative + name; %#ok<AGROW>
        elseif item.isdir && startsWith(name, "+") && strlength(name) > 1
            files = [files; packageFiles(fullfile(folder, name), relative + name + "/", definitions)]; %#ok<AGROW>
        end
    end
end

function items = loadData(path)
    items = struct([]);
    if ~isfile(path)
        return
    end
    S = load(path);
    if isfield(S, "Data") && isstruct(S.Data)
        items = S.Data;
    end
end

function value = getOr(s, name, default)
    value = nansen.internal.getField(s, name, default);
end

function value = textOf(s, name)
    % A text field as char; '' when absent, empty or not text. Objects with a Name (DataLocationType) give that.
    if nargin == 2
        value = getOr(s, name, '');
    else
        value = s;
    end
    if isobject(value) && isprop(value, "Name")
        value = value.Name;
    end
    if isstring(value) && isscalar(value) && ~ismissing(value)
        value = char(value);
    elseif iscategorical(value) && isscalar(value)
        value = char(value);
    end
    if ~ischar(value) || ~(isrow(value) || isempty(value))
        value = '';
    end
end

function items = textList(value)
    if ischar(value) || isstring(value)
        value = cellstr(value);
    end
    if ~iscell(value)
        items = {};
        return
    end
    items = {};
    for i = 1:numel(value)
        if (ischar(value{i}) && isrow(value{i})) || (isstring(value{i}) && isscalar(value{i}))
            items{end + 1} = char(value{i}); %#ok<AGROW>
        end
    end
end
