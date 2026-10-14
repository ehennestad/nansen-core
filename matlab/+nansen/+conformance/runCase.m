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

function detail = runApiCase(folder)
    % Send each request of session.json to a fresh Api, as JSON, and compare the answers as subsets.
    detail = "";
    steps = nansen.internal.asCellOfStructs(nansen.internal.readJson(fullfile(folder, "session.json")).steps);
    listing = [];
    if isfile(fullfile(folder, "listing.json"))
        listing = nansen.internal.readText(fullfile(folder, "listing.json"));
    end
    scratch = string(tempname);
    mkdir(scratch);
    cleanup = onCleanup(@() rmdir(scratch, "s"));
    project = fullfile(scratch, "project");
    if isfolder(fullfile(folder, "project"))
        copyfile(fullfile(folder, "project"), project);
    end
    api = nansen.Api();
    for number = 1:numel(steps)
        step = steps{number};
        text = string(jsonencode(step.request));
        text = replace(text, """${project}""", string(jsonencode(char(project))));
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
