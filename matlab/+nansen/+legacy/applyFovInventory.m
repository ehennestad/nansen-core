function report = applyFovInventory(project, inventory)
%applyFovInventory Put a FOV inventory of NANSEN dev's fovmanager onto a project's FOV map
%
%   report = nansen.legacy.applyFovInventory(project, inventory) takes a
%   nansen.Project with the ophys module and a nansen.legacyFovInventory
%   document (nansen.legacy.exportFovInventory) and writes, as
%   nansen.legacy.planFovInventory plans them: the FOV positions of the
%   sessions (the entity type with ophys.fov_position) and the windows of
%   the subjects (with ophys.cranial_window), the images as BMP files in the
%   project's fovmap folder, and the marks in the ophys module's data
%   (fovmap), where they replace the marks of the same subjects and sessions
%   and get ids after the others, so importing it again changes nothing.
%   report has fovEntityType, windowEntityType, sessions and subjects (the
%   keys of the FOVs and windows placed), injections, notes, photos,
%   outlines and headbars (how many), images (their paths), revision (of
%   the module data) and warnings. As Python's
%   nansen.fovinventory.import_inventory.
    if ~any(arrayfun(@(m) m.Id == "ophys", project.modules()))
        nansen.internal.throwError("unknown-module", "the project does not use the ophys module, whose FOV map this is")
    end
    fovType = "";
    windowType = "";
    for entry = nansen.internal.asCellOfStructs(project.Document.entityTypes)
        fragments = string(nansen.internal.asCellstr(nansen.internal.getField(entry{1}, "fragments", [])));
        if fovType == "" && ismember("ophys.fov_position", fragments)
            fovType = string(entry{1}.name);
        end
        if windowType == "" && ismember("ophys.cranial_window", fragments)
            windowType = string(entry{1}.name);
        end
    end
    if fovType == ""
        nansen.internal.throwError("invalid-params", "no entity type has FOV positions (ophys.fov_position): run the tool ophys.setup_variables first")
    end
    fovTable = project.table(fovType);
    windowKeys = {};
    if windowType ~= ""
        windowTable = project.table(windowType);
        windowKeys = keysOf(windowTable);
    end
    planned = nansen.legacy.planFovInventory(inventory, keysOf(fovTable), windowKeys);
    for i = 1:numel(planned.fovs)
        fovTable.updateRow(planned.fovs{i}.key, planned.fovs{i}.values);
    end
    if ~isempty(planned.fovs)
        fovTable.write();
    end
    for i = 1:numel(planned.windows)
        windowTable.updateRow(planned.windows{i}.key, planned.windows{i}.values);
    end
    if ~isempty(planned.windows)
        windowTable.write();
    end
    paths = {};
    for i = 1:numel(planned.images)
        nansen.legacy.writeFovImage(fullfile(project.Folder, planned.images{i}.path), planned.images{i}.image);
        paths{end + 1} = planned.images{i}.path; %#ok<AGROW>
    end
    path = fullfile(project.Folder, "module-data", "ophys", "fovmap.json");
    stored = [];
    revision = 0;
    if isfile(path)
        document = nansen.readDocument(path, ExpectedType="nansen.moduleData");
        stored = jsondecode(document.text);
        revision = document.revision;
    end
    merged = mergeMarks(stored, planned);
    document = struct("schemaType", 'nansen.moduleData', "schemaVersion", '0.1.0', "module", 'ophys', ...
        "name", 'fovmap', "revision", revision + 1, "text", jsonencode(merged));
    nansen.checkDocument(document, ExpectedType="nansen.moduleData");
    if ~isfolder(fileparts(path))
        mkdir(fileparts(path));
    end
    nansen.internal.writeJson(path, document);
    report = struct("fovEntityType", char(fovType), "windowEntityType", [], ...
        "sessions", {cellfun(@(f) f.key, planned.fovs, UniformOutput=false)}, ...
        "subjects", {cellfun(@(w) w.key, planned.windows, UniformOutput=false)});
    if windowType ~= ""
        report.windowEntityType = char(windowType);
    end
    for kind = ["injections", "notes", "photos", "outlines", "headbars"]
        report.(kind) = numel(planned.marks.(kind));
    end
    report.images = paths;
    report.revision = revision + 1;
    report.warnings = planned.warnings;
end

function keys = keysOf(table)
    % The keys of a table's rows, as structs
    rows = table.toJsonRows();
    keys = cell(1, numel(rows));
    for i = 1:numel(rows)
        key = struct();
        for name = table.Key
            key.(name) = rows{i}.(name);
        end
        keys{i} = key;
    end
end

function merged = mergeMarks(stored, planned)
    % The FOV map's data with the inventory's marks: those stored of its subjects and sessions are replaced by its
    % own, the others kept; its marks get ids after the stored ones. As Python's nansen.fovinventory.merge_marks.
    if isstruct(stored) && isscalar(stored)
        merged = stored;
    else
        merged = struct();
    end
    subjects = cellfun(@keyId, planned.subjects, UniformOutput=false);
    sessions = cellfun(@keyId, planned.sessions, UniformOutput=false);
    for kind = ["injections", "notes", "photos", "outlines", "headbars"]
        kept = {};
        start = 0;
        for item = asMarks(nansen.internal.getField(merged, kind, []))
            mark = item{1};
            subject = nansen.internal.getField(mark, "subject", []);
            session = nansen.internal.getField(mark, "session", []);
            if (isstruct(subject) && isscalar(subject) && ismember(keyId(subject), subjects)) || ...
                    (isstruct(session) && isscalar(session) && ismember(keyId(session), sessions))
                continue
            end
            id = nansen.internal.getField(mark, "id", []);
            if isnumeric(id) && isscalar(id)
                start = max(start, id);
            end
            kept{end + 1} = nullsBack(mark); %#ok<AGROW>
        end
        added = planned.marks.(kind);
        for i = 1:numel(added)
            added{i}.id = start + i;
        end
        merged.(kind) = [kept, added];
    end
end

function items = asMarks(value)
    % The marks of a kind, as decoded: a row cell of structs (others, which the map does not keep, are left out)
    items = {};
    if iscell(value)
        value = value(cellfun(@(v) isstruct(v) && isscalar(v), value));
        items = reshape(value, 1, []);
    elseif isstruct(value)
        items = num2cell(reshape(value, 1, []));
    end
end

function mark = nullsBack(mark)
    % A stored mark as it was saved: jsondecode reads null as [], which jsonencode would write as []
    for name = reshape(string(fieldnames(mark)), 1, [])
        if isnumeric(mark.(name)) && isempty(mark.(name))
            mark.(name) = NaN;
        end
    end
end

function id = keyId(key)
    id = char(jsonencode(orderfields(key)));
end
