function result = runCase(caseId, root)
%runCase Run one conformance case ("kind/name"); result has Passed (logical) and Detail
    arguments
        caseId (1,1) string
        root (1,1) string = nansen.conformance.casesDirectory()
    end
    parts = split(caseId, "/");
    kind = parts(1);
    folder = fullfile(root, kind, parts(2));
    expected = nansen.internal.readJson(fullfile(folder, "expected.json"));
    result = struct("Passed", false, "Detail", "");
    if kind == "api"
        result.Detail = runApiCase(folder);
        result.Passed = result.Detail == "";
        return
    end
    try
        [actual, written] = evaluate(kind, folder, expected);
    catch err
        if ~isa(err, "nansen.NansenError")
            where = "";
            if ~isempty(err.stack)
                where = sprintf(" (in %s at line %d)", err.stack(1).name, err.stack(1).line);
            end
            result.Detail = "unexpected error " + err.identifier + ": " + err.message + where;
            return
        end
        if isfield(expected, "error") && err.Code == string(expected.error)
            result.Passed = true;
        else
            result.Detail = "raised " + err.Code + ": " + err.message;
        end
        return
    end
    if isfield(expected, "error")
        result.Detail = "expected error " + string(expected.error) + ", got a result";
        return
    end
    for name = reshape(string(fieldnames(expected)), 1, [])
        if ismember(name, ["description", "canonical"])
            continue
        end
        if ~isfield(actual, name) || ~isequal(canonical(expected.(name)), canonical(actual.(name)))
            got = "(absent)";
            if isfield(actual, name)
                got = string(jsonencode(actual.(name)));
            end
            result.Detail = name + ": expected " + string(jsonencode(expected.(name))) + ", got " + got;
            return
        end
    end
    if ~isempty(written)
        listing = dir(fullfile(folder, "*.csv"));
        onDisk = string(nansen.internal.readText(fullfile(folder, listing(1).name)));
        if written ~= onDisk
            result.Detail = "writing the rows back gives " + jsonencode(written) + ", expected " + jsonencode(onDisk);
            return
        end
    end
    result.Passed = true;
end

function [actual, written] = evaluate(kind, folder, expected)
    written = [];
    switch kind
        case "documents"
            document = nansen.readDocument(fullfile(folder, "document.json"));
            actual = struct("valid", true, "schemaType", document.schemaType);
        case "tables"
            listing = dir(fullfile(folder, "*.table.nansen.json"));
            table = nansen.EntityTable.read(fullfile(folder, listing(1).name));
            actual = struct("rows", {table.toJsonRows()});
            if isfield(expected, "canonical") && expected.canonical
                % Write from the expected rows, not the parsed ones, so writing is tested on its own.
                fresh = nansen.EntityTable(table.EntityType, table.Key, table.Columns, File=table.File);
                for row = nansen.internal.asCellOfStructs(expected.rows)
                    fresh.addRow(row{1})
                end
                written = fresh.toCsv();
            end
        case "entities"
            actual = evaluateEntities(folder);
        case "data"
            actual = evaluateData(folder);
        case "legacy"
            actual = evaluateLegacy(folder);
        case "jsontext"
            actual = evaluateJsonText(folder);
        case "yaml"   % dev's metadata files (nansen.internal.parseDevYaml)
            actual = struct("value", {nansen.internal.parseDevYaml(nansen.internal.readText(fullfile(folder, "input.yaml")))});
        case "api"
            actual = struct();   % handled by runApiCase
        case "projects"
            project = nansen.Project.open(fullfile(folder, "project"));
            tables = struct();
            for name = project.EntityTypes
                table = project.table(name);
                tables.(name) = struct("key", {cellstr(table.Key)}, "columns", {cellstr(table.columnNames())}, ...
                    "revision", table.Revision, "rows", {table.toJsonRows()});
            end
            actual = struct("name", char(project.Name), "title", char(project.Title), ...
                "entityTypes", {cellstr(project.EntityTypes)}, "tables", tables);
    end
end

function actual = evaluateEntities(folder)
    % Sync writes the tables, so work on a copy.
    scratch = string(tempname);
    copyfile(fullfile(folder, "project"), fullfile(scratch, "project"));
    cleanup = onCleanup(@() rmdir(scratch, "s"));
    project = nansen.Project.open(fullfile(scratch, "project"));
    scan = project.scan(dsm.loadListing(fullfile(folder, "listing.json")), Save=false);
    entities = struct();
    synced = struct();
    for name = project.EntityTypes
        table = project.table(name);
        summaries = cellfun(@(e) nansen.internal.entitySummary(e, table), project.entities(name, scan), ...
            UniformOutput=false);
        entities.(name) = summaries;
    end
    for name = project.EntityTypes
        synced.(name) = project.sync(name, scan);
    end
    actual = struct("entities", entities, "sync", synced);
end

function actual = evaluateJsonText(folder)
    text = nansen.internal.readText(fullfile(folder, "input.json"));
    edits = nansen.internal.asCellOfStructs(nansen.internal.readJson(fullfile(folder, "edits.json")).edits);
    for i = 1:numel(edits)
        edit = edits{i};
        switch string(edit.op)
            case "replace"
                text = nansen.internal.JsonText.replace(text, edit.pointer, edit.value);
            case "append"
                text = nansen.internal.JsonText.append(text, edit.pointer, edit.value);
            otherwise
                text = nansen.internal.JsonText.setMember(text, edit.pointer, edit.key, edit.value);
        end
    end
    actual = struct("output", string(text));
end

function actual = evaluateLegacy(folder)
    % Convert export.json and read back every file the new project holds.
    scratch = string(tempname);
    mkdir(scratch);
    cleanup = onCleanup(@() rmdir(scratch, "s"));
    target = fullfile(scratch, "project");
    report = nansen.legacy.convert(nansen.internal.readJson(fullfile(folder, "export.json")), target);
    project = nansen.Project.open(target);
    tables = struct();
    for name = project.EntityTypes
        table = project.table(name);
        tables.(name) = struct("key", {cellstr(table.Key)}, "columns", {cellstr(table.columnNames())}, ...
            "rows", {table.toJsonRows()});
    end
    presets = {};   % options/<method>/<name>.options.nansen.json, in order of that path
    listing = dir(fullfile(target, "options", "**", "*.options.nansen.json"));
    if ~isempty(listing)
        paths = strings(1, numel(listing));
        for i = 1:numel(listing)
            [~, name, extension] = fileparts(listing(i).folder);   % the method's id, such as ophys.normcorre
            paths(i) = string(name) + string(extension) + "/" + string(listing(i).name);
        end
        [~, order] = sort(paths);
        for i = reshape(order, 1, [])
            presets{end + 1} = nansen.internal.readJson(fullfile(listing(i).folder, listing(i).name)); %#ok<AGROW>
        end
    end
    % queued tasks in their queue order, then the finished ones by when they were made and finished; without their ids
    % (new ones each time), and with the text of their log in place of its path
    tasks = readAll(fullfile(target, "tasks"), "*.task.nansen.json");
    if ~isempty(tasks)
        keys = strings(1, numel(tasks));
        for i = 1:numel(tasks)
            if isfield(tasks{i}, "order")
                keys(i) = sprintf("0|%09d", tasks{i}.order);
            else
                keys(i) = "1|" + string(tasks{i}.createdAt) + "|" + string(nansen.internal.getField(tasks{i}, "finishedAt", ""));
            end
            if isfield(tasks{i}, "log")
                tasks{i}.log = string(nansen.internal.readText(fullfile(target, tasks{i}.log)));
            end
        end
        [~, order] = sort(keys);
        tasks = cellfun(@(t) rmfield(t, "id"), tasks(order), UniformOutput=false);
    end
    runs = {};
    journal = fullfile(target, "runs", "session.runs.jsonl");
    if isfile(journal)
        lines = splitlines(string(nansen.internal.readText(journal)));
        for line = reshape(lines(strlength(lines) > 0), 1, [])
            runs{end + 1} = jsondecode(char(line)); %#ok<AGROW>
        end
    end
    actual = struct( ...
        "project", nansen.internal.readJson(fullfile(target, "project.nansen.json")), ...
        "fileAdapters", {readAll(fullfile(target, "file-adapters"), "*.fileAdapter.nansen.json")}, ...
        "presets", {presets}, "tasks", {tasks}, "runs", {runs}, "settings", report.settings, ...
        "dataset", nansen.internal.readJson(fullfile(target, "dataset.dsm.json")), ...
        "fragments", {readAll(fullfile(target, "fragments"), "*.fragment.nansen.json")}, ...
        "dataVariables", {readAll(fullfile(target, "data-variables"), "*.dataVariable.nansen.json")}, ...
        "notebooks", {readAll(fullfile(target, "notes"), "*.notebook.nansen.json")}, ...
        "views", {readAll(fullfile(target, "views"), "*.views.nansen.json")}, ...
        "pipelines", {readAll(fullfile(target, "pipelines"), "*.pipeline.nansen.json")}, ...
        "methods", {readAll(fullfile(target, "methods"), "*.method.nansen.json")}, ...
        "methodFiles", {filesUnder(fullfile(target, "matlab"))}, ...
        "tables", tables, "warnings", {report.warnings});
end

function files = filesUnder(folder)
    % The paths of the files in a folder and its subfolders, relative to it, '/'-separated and sorted
    files = {};
    if ~isfolder(folder)
        return
    end
    listing = dir(fullfile(folder, "**", "*"));
    listing = listing(~[listing.isdir]);
    paths = strings(1, numel(listing));
    for i = 1:numel(listing)
        paths(i) = replace(string(fullfile(listing(i).folder, listing(i).name)), "\", "/");
    end
    prefix = replace(string(folder), "\", "/") + "/";
    files = cellstr(sort(extractAfter(paths, strlength(prefix))));
end

function documents = readAll(folder, pattern)
    listing = dir(fullfile(folder, pattern));
    names = sort(string({listing.name}));
    documents = arrayfun(@(n) nansen.internal.readJson(fullfile(folder, n)), names, UniformOutput=false);
end

function detail = runApiCase(folder)
    % Send each request of session.json to a fresh Api, as JSON, and compare the answers as subsets.
    detail = "";
    listingOfCase = dir(fullfile(folder, "session.json"));
    caseFolder = string(listingOfCase(1).folder);
    sessionText = string(nansen.internal.readText(fullfile(folder, "session.json")));
    listing = [];
    if isfile(fullfile(folder, "listing.json"))
        listing = nansen.internal.readText(fullfile(folder, "listing.json"));
    end
    scratch = string(tempname);
    mkdir(scratch);
    cleanup = onCleanup(@() rmdir(scratch, "s"));
    % ${scratch} and ${case} may appear inside any string, in requests and expected results alike
    sessionText = replace(sessionText, "${scratch}", jsonContent(replace(scratch, "\", "/")));
    sessionText = replace(sessionText, "${case}", jsonContent(replace(caseFolder, "\", "/")));
    session = jsondecode(char(sessionText));
    steps = nansen.internal.asCellOfStructs(session.steps);
    project = fullfile(scratch, "project");
    if isfolder(fullfile(folder, "project"))
        copyfile(fullfile(folder, "project"), project);
    end
    if isfolder(fullfile(folder, "data"))   % files viewed without a project
        copyfile(fullfile(folder, "data"), fullfile(scratch, "data"));
    end
    viewables = nansen.Viewables();
    if isfield(session, "viewables")
        registerViewables(viewables, nansen.internal.asCellOfStructs(session.viewables));
    end
    api = nansen.Api(Viewables=viewables);
    % the base workspace, the current folder and the figures are left as they are
    api.SendToWorkspace = @(name, value) [];
    api.ChangeFolder = @(folder) [];
    api.CloseFigures = @() 0;
    kept = struct("name", {}, "value", {});   % values a step keeps from its result, as ${name}, for the steps after it
    for number = 1:numel(steps)
        step = steps{number};
        text = string(jsonencode(step.request));
        text = replace(text, """${project}""", string(jsonencode(char(project))));
        for k = 1:numel(kept)
            text = replace(text, """${" + kept(k).name + "}""", string(jsonencode(kept(k).value)));
        end
        if ~isempty(kept) && isfield(step.expect, "result")
            expectText = string(jsonencode(step.expect.result));
            for k = 1:numel(kept)
                expectText = replace(expectText, """${" + kept(k).name + "}""", string(jsonencode(kept(k).value)));
            end
            step.expect.result = jsondecode(char(expectText));
        end
        if ~isempty(listing)
            text = replace(text, """${listing}""", string(listing));
        end
        request = jsondecode(char(text));
        response = jsondecode(char(api.handleJson(text)));
        if ~isequal(response.id, request.id)
            detail = sprintf("step %d: response id does not match the request", number);
            return
        end
        if isfield(step.expect, "error")
            if ~isfield(response, "error") || string(response.error.code) ~= string(step.expect.error)
                detail = sprintf("step %d %s: expected error %s, got %s", number, request.method, ...
                    step.expect.error, extractBefore(jsonencode(response) + string(blanks(400)), 401));
                return
            end
            continue
        end
        if isfield(response, "error")
            detail = sprintf("step %d %s: unexpected error %s: %s", number, request.method, ...
                response.error.code, response.error.message);
            return
        end
        mismatch = subsetMismatch(step.expect.result, response.result, "result");
        if mismatch ~= ""
            detail = sprintf("step %d %s: %s", number, request.method, mismatch);
            return
        end
        if isfield(step, "keep")
            for name = reshape(string(fieldnames(step.keep)), 1, [])
                value = response.result;
                tokens = split(string(step.keep.(name)), "/");
                for token = reshape(tokens(2:end), 1, [])
                    if ~isnan(str2double(token))
                        items = asItems(value);
                        value = items{str2double(token) + 1};
                    else
                        value = value.(token);
                    end
                end
                kept(end + 1) = struct("name", name, "value", {value}); %#ok<AGROW>   % a cell value as it is
            end
        end
    end
end

function registerViewables(viewables, entries)
    % What the case's app is given to view, as nansen.view gives it: {stack, rois?, name?, frameRate?} or
    % {signals, name?, frameRate?}, registered in order (v1, v2, ...)
    for i = 1:numel(entries)
        entry = entries{i};
        name = string(nansen.internal.getField(entry, "name", ""));
        frameRate = nansen.internal.getField(entry, "frameRate", []);
        if isfield(entry, "signals")
            viewables.addSignals(string(entry.signals), Name=name, FrameRate=frameRate);
        else
            rois = nansen.internal.getField(entry, "rois", []);
            if ~isempty(rois)
                rois = string(rois);
            end
            viewables.addStack(string(entry.stack), Name=name, Rois=rois, FrameRate=frameRate);
        end
    end
end

function mismatch = subsetMismatch(expected, actual, where)
    % Where actual fails to contain expected: objects by the expected keys, arrays element by element.
    mismatch = "";
    if isstruct(expected) && isscalar(expected) && ~(isstruct(actual) && ~isscalar(actual)) && ~iscell(actual)
        if ~(isstruct(actual) && isscalar(actual))
            mismatch = where + ": expected an object";
            return
        end
        for name = reshape(string(fieldnames(expected)), 1, [])
            if ~isfield(actual, name)
                mismatch = where + "." + name + ": missing";
                return
            end
            mismatch = subsetMismatch(expected.(name), actual.(name), where + "." + name);
            if mismatch ~= ""
                return
            end
        end
        return
    end
    if iscell(expected) || isstruct(expected) || ((isnumeric(expected) || islogical(expected)) && numel(expected) > 1) ...
            || (isnumeric(expected) && isempty(expected) && (iscell(actual) || isstruct(actual)))
        expectedItems = asItems(expected);
        actualItems = asItems(actual);
        if numel(expectedItems) ~= numel(actualItems)
            mismatch = sprintf("%s: expected %d items, got %d", where, numel(expectedItems), numel(actualItems));
            return
        end
        for i = 1:numel(expectedItems)
            mismatch = subsetMismatch(expectedItems{i}, actualItems{i}, sprintf("%s[%d]", where, i - 1));
            if mismatch ~= ""
                return
            end
        end
        return
    end
    if ischar(expected) || isstring(expected)
        same = (ischar(actual) || isstring(actual)) && string(expected) == string(actual);
    else
        same = isequal(expected, actual);
    end
    if ~same
        mismatch = where + ": expected " + string(jsonencode(expected)) + ", got " + string(jsonencode(actual));
    end
end

function text = jsonContent(value)
    % A string as it appears between the quotes of a JSON string
    text = string(jsonencode(char(value)));
    text = extractBetween(text, 2, strlength(text) - 1);
end

function items = asItems(value)
    if iscell(value)
        items = reshape(value, 1, []);
    elseif isstruct(value) || isnumeric(value) || islogical(value)
        items = num2cell(reshape(value, 1, []));
    else
        items = {value};
    end
end

function actual = evaluateData(folder)
    project = nansen.Project.open(fullfile(folder, "project"));
    scan = project.scan(dsm.loadListing(fullfile(folder, "listing.json")), Save=false);
    requests = nansen.internal.asCellOfStructs(nansen.internal.readJson(fullfile(folder, "requests.json")).requests);
    results = cell(1, numel(requests));
    for i = 1:numel(requests)
        request = requests{i};
        entity = project.entity(request.entityType, request.key, scan);
        result = struct();
        try
            targets = project.readTargets(entity, request.variable);
            result.read = arrayfun(@(r) cellstr(targets(r, :)), 1:size(targets, 1), UniformOutput=false);
        catch err
            result.read = struct("error", char(errorCode(err)));
        end
        try
            [dataLocation, relative] = project.writeTarget(entity, request.variable);
            result.write = cellstr([dataLocation, relative]);
        catch err
            result.write = struct("error", char(errorCode(err)));
        end
        results{i} = result;
    end
    actual = struct("results", {results});
end

function code = errorCode(err)
    if ~isa(err, "nansen.NansenError")
        rethrow(err)
    end
    code = err.Code;
end

function value = canonical(value)
    % One shape for a JSON value whether it came from jsondecode or was built
    % in MATLAB: text as string, arrays as column cells, a one-element array
    % of objects as the object (jsondecode cannot tell them apart), and null
    % and empty arrays as [].
    if ischar(value) || (isstring(value) && isscalar(value))
        value = string(value);
    elseif iscell(value) || (isstruct(value) && ~isscalar(value)) || ((isnumeric(value) || islogical(value)) && numel(value) > 1)
        if ~iscell(value)
            value = num2cell(value);
        end
        value = cellfun(@canonical, reshape(value, [], 1), UniformOutput=false);
        if isempty(value)
            value = [];
        elseif isscalar(value) && isstruct(value{1})
            value = value{1};
        end
    elseif isstruct(value)
        for name = reshape(string(fieldnames(value)), 1, [])
            value.(name) = canonical(value.(name));
        end
        value = orderfields(value);
    elseif isempty(value)
        value = [];
    end
end
