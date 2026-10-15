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
%     configurations/custom_options/*.mat          option presets, by function (OptionsEntries), only named
%
%   Table values become JSON values: text, numbers, logicals and dates.
%   Columns of other types (structs, objects, several columns per variable)
%   are listed in skippedColumns. Empty text and NaN/NaT are null. The notes
%   of a Notebook column (dev's nansen.notes.Note structs) are the table's
%   notes, each with the index of its row.
%
%   exportProject(folder, File=path) also writes the export as JSON, which
%   the Python command `nansen import-legacy` converts as well.
    arguments
        folder (1,1) string
        options.File (1,1) string = ""
    end
    if ~isfolder(folder)
        nansen.internal.throwError("file-not-found", "no folder %s", folder)
    end
    export = struct("schemaType", 'nansen.legacyExport', "schemaVersion", '0.1.0', "source", char(folder));
    export.project = readProjectInfo(folder);
    export.dataLocations = readDataLocations(fullfile(folder, "configurations", "datalocation_settings.mat"));
    export.variables = readVariables(fullfile(folder, "configurations", "filepath_settings.mat"));
    export.tables = readTables(fullfile(folder, "metadata", "tables"));
    export.pipelines = readPipelines(fullfile(folder, "configurations", "pipeline_settings.mat"));
    export.presets = readPresets(fullfile(folder, "configurations", "custom_options"));
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

function tables = readTables(folder)
    tables = {};
    listing = dir(fullfile(folder, "*.mat"));
    for name = sort(string({listing.name}))
        if name == "metatable_catalog.mat"
            continue
        end
        S = load(fullfile(folder, name));
        if ~isfield(S, "MetaTableEntries") || ~istable(S.MetaTableEntries)
            continue
        end
        className = textOf(S, "MetaTableClass");
        parts = split(string(className), ".");
        entries = S.MetaTableEntries;
        [columns, skipped, rows, notes] = readEntries(entries);
        label = textOf(S, "MetaTableName");
        if label == ""
            [~, label] = fileparts(name);
            label = char(label);
        end
        isMaster = getOr(S, "IsMaster", true);
        tables{end + 1} = struct("name", label, "entityClass", char(lower(parts(end))), ...
            "isMaster", ~isempty(isMaster) && logical(isMaster(1)), "columns", {columns}, ...
            "skippedColumns", {cellstr(skipped)}, "notes", {notes}, "rows", {rows}); %#ok<AGROW>
    end
end

function [columns, skipped, rows, notes] = readEntries(entries)
    names = string(entries.Properties.VariableNames);
    columns = {};
    skipped = strings(1, 0);
    values = {};
    kept = strings(1, 0);
    notes = {};
    for name = names
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
    % OptionsManager's files, one per function: the names of the presets a user made (Type Custom)
    presets = {};
    listing = dir(fullfile(folder, "*.mat"));
    for i = 1:numel(listing)
        S = load(fullfile(listing(i).folder, listing(i).name));
        if ~isfield(S, "OptionsEntries") || ~isstruct(S.OptionsEntries)
            continue
        end
        names = {};
        for k = 1:numel(S.OptionsEntries)
            if string(textOf(S.OptionsEntries(k), "Type")) == "Custom"
                names{end + 1} = textOf(S.OptionsEntries(k), "Name"); %#ok<AGROW>
            end
        end
        if ~isempty(names)
            [~, functionName] = fileparts(listing(i).name);
            presets{end + 1} = struct("function", functionName, "names", {names}); %#ok<AGROW>
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
