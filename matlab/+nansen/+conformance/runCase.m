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
