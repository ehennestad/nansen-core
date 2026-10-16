function out = plan(export)
%plan Work out every document of the project made from a legacy export, without writing anything
%
%   The export must be checked already (nansen.legacy.convert does that).
%   plan has fields name, title, description, dataset, modules, fragments,
%   tables, dataVariables, fileAdapters (the project's own file adapters, as
%   nansen.legacy.planFileAdapters plans them), methods (the project's own
%   session methods, as nansen.legacy.planSessionMethods plans them),
%   columnMethods (the methods of the computed columns of dev's table
%   variable functions: document, and files with path and text),
%   presets (method, name, description, values), preferredPresets,
%   pipelines, tasks (method, name, entities, values and preset, createdAt
%   and comment when there are; a task of dev's history also has status,
%   and startedAt, finishedAt, log and error when there are), runs
%   (method, key, finishedAt), settings and warnings; see
%   nansen.legacy.convert.
    warnings = {};
    info = nansen.internal.getField(export, "project", struct());
    [dataset, levels, warnings] = buildDataset(export, warnings);
    [adapters, warnings] = buildFileAdapters(export, warnings);
    byName = containers.Map("KeyType", "char", "ValueType", "any");   % dev's name of an adapter (lower case) -> its entry
    for i = 1:numel(adapters)
        if strlength(adapters{i}.name) > 0 && ~isKey(byName, char(lower(adapters{i}.name)))
            byName(char(lower(adapters{i}.name))) = adapters{i};
        end
    end
    [variables, dataset, warnings] = buildDataVariables(export, dataset, levels, byName, warnings);
    [fragments, tables, warnings] = buildTables(export, dataset, warnings);
    [fragments, tables, columnMethods, warnings] = buildTableVariables(export, tables, fragments, warnings);
    [fragments, tables, warnings] = buildLayouts(export, tables, fragments, warnings);
    [methods_, warnings] = buildSessionMethods(export, warnings);
    imported = containers.Map("KeyType", "char", "ValueType", "char");   % dev's function name -> method id
    for i = 1:numel(methods_)
        imported(char(methods_{i}.function)) = methods_{i}.document.id;
    end
    [presets, preferred, presetNames, presetWarnings] = buildPresets(export, imported, {});
    [pipelines, pipelineIds, warnings] = buildPipelines(export, imported, presetNames, warnings);
    warnings = [warnings, presetWarnings];
    [tables, runs, warnings] = buildProgress(tables, pipelineIds, imported, warnings);
    session = [];
    for i = 1:numel(tables)
        if string(tables{i}.entityType) == "session"
            session = tables{i};
        end
    end
    [tasks, done, warnings] = buildTaskList(export, session, imported, presetNames, warnings);
    runs = orderedRuns([done, runs]);
    for i = 1:numel(tables)
        if isfield(tables{i}, "progress")
            tables{i} = rmfield(tables{i}, "progress");
        end
        if isfield(tables{i}, "layout")
            tables{i} = rmfield(tables{i}, "layout");
        end
    end
    if ~isempty(pipelines)   % sessions keep the pipeline they follow, and its progress, in core.pipeline
        for i = 1:numel(tables)
            if string(tables{i}.entityType) == "session" && ~ismember("core.pipeline", string(tables{i}.fragments))
                tables{i}.fragments{end + 1} = 'core.pipeline';
            end
        end
    end
    [tables, moduleData, images, warnings] = buildFovInventory(export, tables, warnings);
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
    % the ophys module, when a variable is read by one of its adapters (dev's ROI files and image stacks), or so is a
    % file of one of the project's own adapters built on dev's, or a pipeline, preset, task or completed run is of
    % one of its methods
    modules = "core";
    usesOphys = any(cellfun(@(v) startsWith(string(v.fileAdapter), "ophys."), variables));
    for i = 1:numel(adapters)
        if isfield(adapters{i}, "reads") && isfield(adapters{i}.document.legacyFileAdapter, "builtIn")
            usesOphys = usesOphys || any(cellfun(@(b) startsWith(string(b.fileAdapter), "ophys."), ...
                adapters{i}.document.legacyFileAdapter.builtIn));
        end
    end
    for i = 1:numel(pipelines)
        usesOphys = usesOphys || any(cellfun(@(step) startsWith(string(step.method), "ophys."), pipelines{i}.steps));
    end
    usesOphys = usesOphys || any(cellfun(@(item) startsWith(string(item.method), "ophys."), [presets, tasks, runs]));
    for i = 1:numel(tables)   % dev's FOV inventory, on the ophys module's FOV map
        usesOphys = usesOphys || any(ismember(["ophys.fov_position", "ophys.cranial_window"], string(tables{i}.fragments)));
    end
    usesOphys = usesOphys || ~isempty(moduleData);
    if usesOphys
        modules(end + 1) = "ophys";
    end
    out = struct("name", name, "title", title, "description", textOf(info, "description"), ...
        "dataset", dataset, "modules", modules, "fragments", {fragments}, "tables", {tables}, "dataVariables", {variables}, ...
        "fileAdapters", {adapters}, "methods", {methods_}, "columnMethods", {columnMethods}, ...
        "presets", {presets}, "preferredPresets", {preferred}, ...
        "pipelines", {pipelines}, "tasks", {tasks}, "runs", {runs}, "settings", settingsOf(export), ...
        "moduleData", {moduleData}, "images", {images}, "warnings", {warnings});
end

% -- dev's FOV inventory ------------------------------------------------------------------------

function [tables, moduleData, images, warnings] = buildFovInventory(export, tables, warnings)
    % dev's FOV inventory (fovmanager's) on the FOV map (nansen.legacy.planFovInventory): the sessions' FOV positions
    % and the subjects' windows go into their rows, with ophys.fov_position and ophys.cranial_window; a subject that
    % dev's sessions name but its table has no row of gets one for its window. moduleData is {module, name, value} of
    % the FOV map's marks, images {path, image} of the files to write.
    moduleData = {};
    images = {};
    inventory = nansen.internal.getField(export, "fovInventory", []);
    if isempty(inventory)
        return
    end
    nansen.checkDocument(inventory, ExpectedType="nansen.legacyFovInventory", Source="legacy export: fovInventory", ...
        Decoded=true);
    session = 0;
    subject = 0;
    for i = 1:numel(tables)
        if string(tables{i}.entityType) == "session"
            session = i;
        elseif string(tables{i}.entityType) == "subject"
            subject = i;
        end
    end
    sessions = {};
    subjects = {};
    if session
        sessions = cellfun(@(row) keyOfRow(tables{session}, row), tables{session}.rows, UniformOutput=false);
    end
    if subject
        subjects = cellfun(@(row) keyOfRow(tables{subject}, row), tables{subject}.rows, UniformOutput=false);
        if isequal(string(tables{subject}.key(:, 1))', "subject_id") && session   % the subjects of the sessions, too
            for r = 1:numel(tables{session}.rows)
                value = nansen.internal.getField(tables{session}.rows{r}, "subject_id", []);
                if (ischar(value) || isstring(value)) && ~any(cellfun(@(k) isequal(string(k.subject_id), string(value)), subjects))
                    subjects{end + 1} = struct("subject_id", char(value)); %#ok<AGROW>
                end
            end
        end
    end
    planned = nansen.legacy.planFovInventory(inventory, sessions, subjects);
    for i = 1:numel(planned.warnings)
        warnings{end + 1} = char("FOV inventory: " + string(planned.warnings{i})); %#ok<AGROW>
    end
    places = {session, planned.fovs, 'ophys.fov_position'; subject, planned.windows, 'ophys.cranial_window'};
    for p = 1:size(places, 1)
        [at, placed, fragment] = places{p, :};
        if isempty(placed)
            continue
        end
        table = tables{at};
        for i = 1:numel(placed)
            row = 0;
            for r = 1:numel(table.rows)
                if isequal(keyOfRow(table, table.rows{r}), placed{i}.key)
                    row = r;
                    break
                end
            end
            if row == 0
                table.rows{end + 1} = placed{i}.key;
                row = numel(table.rows);
            end
            for name = reshape(string(fieldnames(placed{i}.values)), 1, [])
                table.rows{row}.(name) = placed{i}.values.(name);
            end
        end
        if ~ismember(string(fragment), string(table.fragments))
            table.fragments{end + 1} = fragment;
        end
        tables{at} = table;
    end
    marks = planned.marks;
    if any(structfun(@(kind) ~isempty(kind), marks))
        moduleData = {struct("module", 'ophys', "name", 'fovmap', "value", marks)};
    end
    images = planned.images;
end

function key = keyOfRow(table, row)
    % A row's key, a struct of the table's key columns
    key = struct();
    for k = 1:size(table.key, 1)
        name = table.key{k, 1};
        key.(name) = nansen.internal.getField(row, name, []);
    end
end

% -- file adapters, presets, task list and progress ---------------------------------------------

function [adapters, warnings] = buildFileAdapters(export, warnings)
    % The project's own file adapters (code/+<package>/+fileadapter), as file adapters that run dev's code in MATLAB
    % (nansen.legacy.planFileAdapters)
    items = listOf(nansen.internal.getField(export, "fileAdapters", {}));
    sources = cell(1, numel(items));
    for i = 1:numel(items)
        sources{i} = struct("file", textOf(items{i}, "file"), "text", string(nansen.internal.getField(items{i}, "text", "")));
    end
    [adapters, skipped] = nansen.legacy.planFileAdapters(sources);
    warnings = [warnings, skipped];
end

function method = methodOf(functionName, imported)
    % The method here of a dev function ("" for none): one of the project's own session methods, imported, or the
    % equivalent of one of dev's (by the end of its name, or the class whose options its presets are kept under)
    method = "";
    functionName = string(functionName);
    optionClasses = ["nansen.wrapper.normcorre.Processor", "ophys.normcorre"; "nansen.wrapper.quicky.Processor", "ophys.quicky"];
    if hasKey(imported, functionName)
        method = string(imported(char(functionName)));
    elseif ismember(functionName, optionClasses(:, 1))
        method = optionClasses(optionClasses(:, 1) == functionName, 2);
    else
        parts = split(functionName, ".");
        count = numel(parts);
        key = lower(strjoin(parts(max(1, count - 1):count), "_"));
        methods_ = devMethods();
        if isvarname(char(key)) && isfield(methods_, key)
            method = string(methods_.(key));
        end
    end
end

function tf = hasKey(map, key)
    % isKey for text that may be empty, which a containers.Map does not take as a key
    tf = strlength(string(key)) > 0 && isKey(map, char(key));
end

function [presets, preferred, names, warnings] = buildPresets(export, imported, warnings)
    % The option presets users made in dev (OptionsManager's Custom entries), as presets of the method here: those of
    % the project's own session methods as dev saved them, those of NoRMCorre and Quicky with dev's options mapped to
    % the module method's (devOptions). Also the preferred presets (dev's DefaultOptionsName, when a user chose one)
    % and each preset's name here by "k:<method>|<dev's name>". As Python's legacy._presets.
    presets = {};
    preferred = {};
    names = containers.Map("KeyType", "char", "ValueType", "char");
    used = containers.Map("KeyType", "char", "ValueType", "any");   % method -> the names given
    for entry = listOf(nansen.internal.getField(export, "presets", {}))
        item = entry{1};
        functionName = textOf(item, "function");
        listed = "";
        listedNames = nansen.internal.asCellstr(nansen.internal.getField(item, "names", {}));
        if ~isempty(listedNames)
            listed = strjoin(string(listedNames), ", ");
        end
        method = methodOf(functionName, imported);
        if method == ""
            if listed ~= ""   % (an item with no names only says which preset dev runs the function with)
                warnings{end + 1} = sprintf("option presets of %s (%s) are not carried over: %s has no method here", ...
                    functionName, listed, functionName); %#ok<AGROW>
            end
            continue
        end
        legacy = hasKey(imported, functionName);
        if ~legacy && ~ismember(method, ["ophys.normcorre", "ophys.quicky"])
            if listed ~= ""
                warnings{end + 1} = sprintf("option presets of %s (%s) are not carried over: dev's options of %s have no equivalent in %s", ...
                    functionName, listed, functionName, method); %#ok<AGROW>
            end
            entries = {};
        elseif ~isfield(item, "entries")
            if listed ~= ""
                warnings{end + 1} = sprintf("option presets of %s (%s) are not carried over: the export holds no values of them", ...
                    functionName, listed); %#ok<AGROW>
            end
            entries = {};
        else
            entries = listOf(item.entries);
        end
        for e = 1:numel(entries)
            devName = textOf(entries{e}, "name");
            where = sprintf("option preset '%s' of %s", devName, functionName);
            [name, used] = presetName(devName, method, used);
            if lower(strtrim(devName)) == "default"
                warnings{end + 1} = sprintf("%s: imported as '%s', since 'default' is the method's own defaults here", where, name); %#ok<AGROW>
            end
            skipped = nansen.internal.asCellstr(nansen.internal.getField(entries{e}, "skippedOptions", {}));
            if ~isempty(skipped)
                warnings{end + 1} = sprintf("%s: %s hold values with no JSON form; left out", where, strjoin(string(skipped), ", ")); %#ok<AGROW>
            end
            options = nansen.internal.getField(entries{e}, "options", struct());
            if ~(isstruct(options) && isscalar(options))
                options = struct();
            end
            if legacy
                values = options;
            else
                [values, unmapped] = mappedOptions(method, options);
                if ~isempty(unmapped)
                    warnings{end + 1} = sprintf("%s: dev's options %s have no equivalent in %s; left out", ...
                        where, strjoin(unmapped, ", "), method); %#ok<AGROW>
                end
            end
            presets{end + 1} = struct("method", char(method), "name", char(name), ...
                "description", char(textOf(entries{e}, "description")), "values", values); %#ok<AGROW>
            names(char("k:" + method + "|" + devName)) = char(name);
        end
        default = textOf(item, "defaultName");
        target = "";
        if isKey(names, char("k:" + method + "|" + default))
            target = string(names(char("k:" + method + "|" + default)));
        elseif lower(default) ~= "default" && default ~= ""
            target = devPreset(method, default);
        end
        if default ~= "" && target ~= ""   % the preset dev ran the method with when none was chosen
            preferred = preferred(~cellfun(@(p) string(p.method) == method, preferred));
            preferred{end + 1} = struct("method", char(method), "preset", char(target)); %#ok<AGROW>
        end
    end
end

function [name, used] = presetName(devName, method, used)
    % A preset's name here: dev's, with characters other than letters, digits, _, . and - as _, and not 'default'
    text = regexprep(char(strtrim(devName)), '[^A-Za-z0-9_.-]+', '_');
    text = regexprep(text, '^[_.]+|[_.]+$', '');
    if isempty(text)
        text = 'preset';
    end
    if strcmpi(text, 'default')
        text = [text, '_dev'];
    end
    taken = strings(1, 0);
    if isKey(used, char(method))
        taken = used(char(method));
    end
    name = string(text);
    n = 2;
    while ismember(name, taken)
        name = string(text) + "_" + n;
        n = n + 1;
    end
    used(char(method)) = [taken, name];
end

function mapping = devOptions(method)
    % dev's options of NoRMCorre and Quicky (nansen.wrapper.normcorre.Options, flufinder.getDefaultOptions), by their
    % path, and the module method's option of the same meaning ("": covered by another; numCols is patches as
    % numRows is). As Python's legacy.DEV_OPTIONS.
    if method == "ophys.normcorre"
        mapping = ["Configuration.numRows", "patches"; "Configuration.numCols", ""; ...
            "Configuration.patchOverlap", "overlap"; "Template.initialBatchSize", "initialBatchSize"; ...
            "Template.updateTemplate", "updateTemplate"; "Template.binWidth", "binWidth"; ...
            "Correction.maximumShift", "maxShift"; "Correction.maximumDeviation", "maxDeviation"; ...
            "Correction.subpixelUpsampling", "upsampling"; "Correction.numIterations", "iterations"];
    else
        mapping = ["General.RoiDiameter", "roiDiameter"; "Preprocessing.BinningSize", "binSize"; ...
            "Preprocessing.SmoothingSigma", "smoothingSigma"; "Detection.PrctileForBinarization", "binarizationPercentile"; ...
            "Detection.NumObservationsRequired", "observationsRequired"; "Detection.MaxNumRois", "maxRois"; ...
            "Detection.UseShapeDetection", "useShapeDetection"; "Detection.InnerRadius", "innerRadius"; ...
            "Detection.OuterRadius", "outerRadius"];
    end
end

function [values, unmapped] = mappedOptions(method, options)
    % dev's options of NoRMCorre or Quicky (nested) as the module method's: each that devOptions maps, a row ([y, x, z]
    % shifts and overlaps) as its first value; and the paths of those it does not map
    [values, unmapped] = walkOptions(options, "", devOptions(method), struct(), strings(1, 0));
end

function [values, unmapped] = walkOptions(node, prefix, mapping, values, unmapped)
    for key = reshape(string(fieldnames(node)), 1, [])
        value = node.(key);
        path = prefix + key;
        at = find(mapping(:, 1) == path, 1);
        if isstruct(value) && isscalar(value)
            [values, unmapped] = walkOptions(value, path + ".", mapping, values, unmapped);
        elseif isempty(at)
            unmapped(end + 1) = path; %#ok<AGROW>
        elseif mapping(at, 2) ~= ""
            if iscell(value)
                if isempty(value)
                    value = [];
                else
                    value = value{1};
                end
            elseif (isnumeric(value) || islogical(value)) && numel(value) > 1
                value = value(1);
            end
            if ~(isnumeric(value) && isempty(value))   % null, or an empty row
                values.(char(mapping(at, 2))) = value;
            end
        end
    end
end

function [tables, runs, warnings] = buildProgress(tables, pipelineIds, imported, warnings)
    % dev's Progress column: each session's pipeline (when it was imported) in core.pipeline, and the pipeline tasks dev
    % marked finished, with their date, as completed runs of their method
    runs = {};
    for t = 1:numel(tables)
        if ~isfield(tables{t}, "progress") || string(tables{t}.entityType) ~= "session"   % dev's pipelines are of sessions
            continue
        end
        progress = tables{t}.progress;
        absent = 0;
        undone = 0;
        undated = 0;
        for r = 1:numel(progress.rows)
            entry = progress.rows{r};
            pipeline = textOf(entry.item, "pipeline");
            if isKey(pipelineIds, char("k:" + pipeline))
                tables{t}.rows{entry.index}.pipeline = pipelineIds(char("k:" + pipeline));
            elseif pipeline ~= ""
                absent = absent + 1;
            end
            for task = listOf(nansen.internal.getField(entry.item, "tasks", {}))
                method = methodOf(textOf(task{1}, "function"), imported);
                finishedAt = textOf(task{1}, "finishedAt");
                if method == ""
                    undone = undone + 1;
                elseif finishedAt == ""
                    undated = undated + 1;
                else
                    runs{end + 1} = struct("method", char(method), "key", entry.key, "finishedAt", char(finishedAt)); %#ok<AGROW>
                end
            end
        end
        label = progress.label;
        if absent
            warnings{end + 1} = sprintf("table '%s': %d row(s) follow a dev pipeline that is not here; they get no pipeline", label, absent); %#ok<AGROW>
        end
        if undone
            warnings{end + 1} = sprintf("table '%s': %d finished pipeline task(s) of a method not here; left out", label, undone); %#ok<AGROW>
        end
        if undated
            warnings{end + 1} = sprintf("table '%s': %d finished pipeline task(s) with no date; left out", label, undated); %#ok<AGROW>
        end
    end
end

function [keys, missing] = sessionKeys(session, ids)
    % The keys of the sessions of these dev session ids that the session table has, and the ids it has not
    keys = {};
    missing = strings(1, 0);
    seen = strings(1, 0);
    for id = reshape(string(ids), 1, [])
        found = [];
        if ~isempty(session)
            for m = 1:numel(session.rows)
                row = session.rows{m};
                if isfield(row, "session_id") && isequal(string(row.session_id), id)
                    found(end + 1) = m; %#ok<AGROW>
                end
            end
        end
        if numel(found) ~= 1
            missing(end + 1) = id; %#ok<AGROW>
            continue
        end
        key = struct();
        for name = reshape(string(session.key(:, 1)), 1, [])
            key.(name) = session.rows{found}.(name);
        end
        keyId = string(nansen.internal.runKeyId(key));
        if ~ismember(keyId, seen)
            seen(end + 1) = keyId; %#ok<AGROW>
            keys{end + 1} = key; %#ok<AGROW>
        end
    end
end

function [tasks, runs, warnings] = buildTaskList(export, session, imported, presetNames, warnings)
    % dev's task list: its queued tasks of a method here, on the sessions here (put on hold when written), and its
    % history's completed tasks as completed runs
    tasks = {};
    runs = {};
    taskList = nansen.internal.getField(export, "tasks", struct());
    for entry = listOf(nansen.internal.getField(taskList, "queue", {}))
        item = entry{1};
        functionName = textOf(item, "function");
        label = textOf(item, "name");
        where = sprintf("queued task '%s' (%s)", label, functionName);
        method = methodOf(functionName, imported);
        if method == ""
            warnings{end + 1} = sprintf("%s has no method here; left out", where); %#ok<AGROW>
            continue
        end
        ids = string(nansen.internal.asCellstr(nansen.internal.getField(item, "entities", {})));
        if isempty(ids)
            warnings{end + 1} = sprintf("%s: the task list does not name its sessions; left out", where); %#ok<AGROW>
            continue
        end
        [keys, missing] = sessionKeys(session, ids);
        if ~isempty(missing)
            tail = "left out";
            if ~isempty(keys)
                tail = "left out of it";
            end
            warnings{end + 1} = sprintf("%s: %s not in the session table; %s", where, strjoin(missing, ", "), tail); %#ok<AGROW>
        end
        if isempty(keys)
            continue
        end
        [values, preset, unmapped] = taskOptions(item, functionName, method, imported, presetNames);
        if unmapped
            warnings{end + 1} = sprintf("%s: dev's options are not the method's here; it starts from the method's defaults", where); %#ok<AGROW>
        end
        task = struct("method", char(method), "name", char(label), "entities", {keys}, "values", values);
        if preset ~= ""
            task.preset = char(preset);
        end
        for field = ["createdAt", "comment"]
            if textOf(item, field) ~= ""
                task.(field) = char(textOf(item, field));
            end
        end
        tasks{end + 1} = task; %#ok<AGROW>
    end
    finished = {};
    recorded = 0;
    left = 0;
    for entry = listOf(nansen.internal.getField(taskList, "history", {}))
        item = entry{1};
        functionName = textOf(item, "function");
        method = methodOf(functionName, imported);
        keys = sessionKeys(session, string(nansen.internal.asCellstr(nansen.internal.getField(item, "entities", {}))));
        switch lower(textOf(item, "status"))   % dev's TaskProcessor: Completed, Failed, Canceled
            case "completed"
                status = "completed";
            case "failed"
                status = "failed";
            case {"canceled", "cancelled"}
                status = "cancelled";
            otherwise
                status = "";
        end
        if method == "" || isempty(keys) || status == ""
            left = left + 1;
            continue
        end
        finishedAt = textOf(item, "finishedAt");
        if status == "completed" && finishedAt ~= ""
            for k = 1:numel(keys)
                runs{end + 1} = struct("method", char(method), "key", keys{k}, "finishedAt", char(finishedAt)); %#ok<AGROW>
            end
            recorded = recorded + 1;
        end
        [values, preset] = taskOptions(item, functionName, method, imported, presetNames);
        task = struct("method", char(method), "name", char(textOf(item, "name")), "entities", {keys}, ...
            "values", values, "status", char(status));
        if preset ~= ""
            task.preset = char(preset);
        end
        for field = ["createdAt", "startedAt", "finishedAt", "comment", "log"]
            if textOf(item, field) ~= ""
                task.(field) = char(textOf(item, field));
            end
        end
        problem = nansen.internal.getField(item, "error", []);
        if isstruct(problem) && isscalar(problem)
            task.error = problem;
        end
        finished{end + 1} = task; %#ok<AGROW>
    end
    if ~isempty(finished) || left
        warnings{end + 1} = sprintf("task history: %d task(s) are finished tasks of the queue, with dev's log, " + ...
            "%d completed one(s) also in the run journal; %d left out " + ...
            "(of a method or session not here, or neither completed, failed nor cancelled)", numel(finished), recorded, left);
    end
    tasks = [tasks, finished];
end

function [values, preset, unmapped] = taskOptions(item, functionName, method, imported, presetNames)
    % A dev task's options here, the preset they are over ("" for none), and whether dev's options were left out (they
    % are not the method's, and no preset holds dev's values): the project's own methods take dev's options as they
    % are; NoRMCorre and Quicky dev's mapped (devOptions) over the module's preset of dev's; other methods start from
    % that preset. As Python's _task_options.
    devName = textOf(item, "preset");
    options = nansen.internal.getField(item, "options", struct());
    if ~(isstruct(options) && isscalar(options))
        options = struct();
    end
    preset = "";
    if isKey(presetNames, char("k:" + method + "|" + devName))
        preset = string(presetNames(char("k:" + method + "|" + devName)));
    end
    unmapped = false;
    if hasKey(imported, functionName)
        values = options;
        return
    end
    if preset == ""
        preset = devPreset(method, devName);
    end
    if ismember(method, ["ophys.normcorre", "ophys.quicky"])
        values = mappedOptions(method, options);
    else
        values = struct();
        unmapped = ~isempty(fieldnames(options)) && preset == "";
    end
end

function runs = orderedRuns(runs)
    % Runs once each, in the order they finished (those of the same time in the order given)
    seen = strings(1, 0);
    keep = true(1, numel(runs));
    for i = 1:numel(runs)
        identity = string(runs{i}.method) + char(30) + nansen.internal.runKeyId(runs{i}.key) + char(30) + runs{i}.finishedAt;
        keep(i) = ~ismember(identity, seen);
        seen(end + 1) = identity; %#ok<AGROW>
    end
    runs = runs(keep);
    if ~isempty(runs)
        [~, order] = sort(string(cellfun(@(r) r.finishedAt, runs, UniformOutput=false)));
        runs = runs(order);
    end
end

function settings = settingsOf(export)
    % dev's app preferences (nansen.App's settings) that are app settings here, in the shape of settings.save:
    % AutosaveMetadataToDataFolders is tables.saveToDataFolders; TableFontSize is tables.textSize (compact up to 9,
    % large from 13, else normal: dev's default, 10, is normal); AllowTableEdits off is tables.locked;
    % RunTasksWhenQueued or RunTasksOnStartup is queue.autoStart (the worker starts with the app, and takes tasks as
    % they are queued); SessionTaskDebug is queue.debug. (ShowIgnoredEntries is a filter of the tables' views:
    % buildLayouts.)
    settings = struct();
    dev = nansen.internal.getField(export, "settings", struct());
    table = nansen.internal.getField(dev, "MetadataTable", struct());
    processor = nansen.internal.getField(dev, "TaskProcessor", struct());
    tables = struct();
    value = nansen.internal.getField(table, "AutosaveMetadataToDataFolders", []);
    if islogical(value) && isscalar(value)
        tables.saveToDataFolders = value;
    end
    value = nansen.internal.getField(table, "TableFontSize", []);
    if isnumeric(value) && isscalar(value) && isfinite(value) && value > 0
        if value <= 9
            tables.textSize = 'compact';
        elseif value >= 13
            tables.textSize = 'large';
        else
            tables.textSize = 'normal';
        end
    end
    value = nansen.internal.getField(table, "AllowTableEdits", []);
    if islogical(value) && isscalar(value)
        tables.locked = ~value;
    end
    if ~isempty(fieldnames(tables))
        settings.tables = tables;
    end
    flags = false(1, 0);
    for name = ["RunTasksWhenQueued", "RunTasksOnStartup"]
        value = nansen.internal.getField(processor, name, []);
        if islogical(value) && isscalar(value)
            flags(end + 1) = value; %#ok<AGROW>
        end
    end
    if ~isempty(flags)
        settings.queue = struct("autoStart", any(flags));
    end
    session = nansen.internal.getField(dev, "Session", struct());
    value = nansen.internal.getField(session, "SessionTaskDebug", []);
    if islogical(value) && isscalar(value)   % stop in the debugger where a method run now fails
        if isfield(settings, "queue")
            settings.queue.debug = value;
        else
            settings.queue = struct("debug", value);
        end
    end
end

% -- session methods, pipelines and presets ----------------------------------------------------

function [methods_, warnings] = buildSessionMethods(export, warnings)
    % The project's own session methods, as methods of sessions that run dev's code (nansen.legacy.planSessionMethods)
    items = listOf(nansen.internal.getField(export, "sessionMethods", {}));
    sources = cell(1, numel(items));
    for i = 1:numel(items)
        file = textOf(items{i}, "file");
        sources{i} = struct("where", file, "function", nansen.legacy.functionName(file), ...
            "text", string(nansen.internal.getField(items{i}, "text", "")));
    end
    [methods_, skipped] = nansen.legacy.planSessionMethods(sources, "session");
    warnings = [warnings, skipped];
end

function methods_ = devMethods()
    % dev's session methods, by the end of their function name (lower case, _ for .), and the method that does the
    % same here (Python's legacy.DEV_METHODS)
    methods_ = struct("motioncorrection_normcorre", "ophys.normcorre", "motioncorrection_flowreg", "ophys.flowreg", ...
        "autosegmentation_quicky", "ophys.quicky", "autosegmentation_suite2p", "ophys.suite2p", ...
        "autosegmentation_extract", "ophys.extract", "signalextraction_extractsignals", "ophys.extract_signals", ...
        "signalextraction_extractsignalsmultichannel", "ophys.extract_signals", ...
        "signalextraction_computedff", "ophys.compute_dff", "deconvolution_caiman", "ophys.caiman_deconvolution", ...
        "imageprocessing_downsamplestack", "ophys.downsample", "imageprocessing_denoisestack", "ophys.deep_interpolation", ...
        "data_backup", "core.backup");
end

function [pipelines, pipelineIds, warnings] = buildPipelines(export, imported, presetNames, warnings)
    % dev's pipelines of sessions, with the tasks that have a method here (one of dev's that has an equivalent, or
    % one of the project's own session methods, imported), and their rules for new sessions; and each one's id by
    % "k:<dev's name of it>"
    methods_ = devMethods();
    pipelineIds = containers.Map("KeyType", "char", "ValueType", "char");
    idColumns = struct("sessionID", "session_id", "SessionID", "session_id", "subjectID", "subject_id", "SubjectID", "subject_id");
    pipelines = {};
    ids = strings(0);
    items = listOf(nansen.internal.getField(export, "pipelines", {}));
    for i = 1:numel(items)
        item = items{i};
        label = textOf(item, "name");
        steps = {};
        tasks = listOf(nansen.internal.getField(item, "tasks", {}));
        for t = 1:numel(tasks)
            task = tasks{t};
            functionName = textOf(task, "function");
            parts = split(functionName, ".");
            count = numel(parts);
            key = lower(strjoin(parts(max(1, count - 1):count), "_"));
            if hasKey(imported, functionName)
                method = string(imported(char(functionName)));
            elseif isvarname(char(key)) && isfield(methods_, key)
                method = string(methods_.(key));
            else
                warnings{end + 1} = sprintf("pipeline '%s': task '%s' (%s) has no method here; left out", label, textOf(task, "name"), functionName); %#ok<AGROW>
                continue
            end
            stepTitle = textOf(task, "name");
            if stepTitle == ""
                stepTitle = method;
            end
            preset = textOf(task, "preset");
            step = struct("method", char(method), "title", char(stepTitle));
            shipped = devPreset(method, preset);
            if preset ~= "" && isKey(presetNames, char("k:" + method + "|" + preset))   % a preset a user made, imported
                step.preset = presetNames(char("k:" + method + "|" + preset));
            elseif shipped ~= ""   % the module's preset of dev's values
                step.preset = char(shipped);
            elseif preset ~= "" && lower(preset) ~= "default"
                warnings{end + 1} = sprintf("pipeline '%s': task '%s' used dev's option preset '%s', which is not carried over; the method's defaults are used", ...
                    label, textOf(task, "name"), preset); %#ok<AGROW>
            end
            steps{end + 1} = step; %#ok<AGROW>
        end
        if isempty(steps)
            warnings{end + 1} = sprintf("pipeline '%s': none of its tasks has a method here; left out", label); %#ok<AGROW>
            continue
        end
        [id, ids] = uniqueName(identifier(label, "pipeline", true), ids);
        pipelineTitle = label;
        if pipelineTitle == ""
            pipelineTitle = "Imported pipeline";
        end
        document = struct("schemaType", 'nansen.pipeline', "schemaVersion", '0.1.0', "id", char("legacy." + id), ...
            "version", '1.0.0', "title", char(pipelineTitle), "entityType", 'session', "steps", {steps});
        rules = {};
        assign = listOf(nansen.internal.getField(item, "assign", {}));
        for r = 1:numel(assign)
            variable = textOf(assign{r}, "variable");
            if isvarname(char(variable)) && isfield(idColumns, variable)
                column = string(idColumns.(variable));
            else
                column = identifier(variable, "column", false);
            end
            mode = lower(textOf(assign{r}, "mode"));
            if ~ismember(mode, ["contains", "match"])
                warnings{end + 1} = sprintf("pipeline '%s': an assignment rule of mode '%s' is not carried over", label, mode); %#ok<AGROW>
                continue
            end
            op = "in";
            if mode == "contains"
                op = "contains";
            end
            rules{end + 1} = struct("column", char(column), "op", char(op), "values", {{char(textOf(assign{r}, "expression"))}}); %#ok<AGROW>
        end
        if ~isempty(rules)
            document.assignWhen = rules;
        end
        pipelines{end + 1} = document; %#ok<AGROW>
        if ~isKey(pipelineIds, char("k:" + label))
            pipelineIds(char("k:" + label)) = document.id;
        end
    end
end

function name = devPreset(method, preset)
    % The module preset with the values of dev's preset of the method ("" for none), as Python's legacy.DEV_PRESETS:
    % dev's Default of Quicky is its Soma values, of NoRMCorre its 4 x 4 nonrigid
    if preset == ""
        preset = "default";
    end
    key = string(regexprep(lower(strtrim(char(preset))), '[\s-]+', '_'));
    name = "";
    switch string(method)
        case "ophys.quicky"
            names = dictionaryOf(["default", "soma", "soma_virus", "axon"], ["soma", "soma", "soma_virus", "axon"]);
        case "ophys.normcorre"
            names = dictionaryOf(["default", "nonrigid", "rigid"], ["nonrigid", "nonrigid", "rigid"]);
        otherwise
            return
    end
    if isKey(names, char(key))
        name = string(names(char(key)));
    end
end

function map = dictionaryOf(keys, values)
    map = containers.Map(cellstr(keys), cellstr(values));
end

function items = listOf(value)
    % A JSON array as jsondecode gives it (a struct array, or a cell when its objects differ) as a cell array
    if isstruct(value)
        items = num2cell(reshape(value, 1, []));
    elseif iscell(value)
        items = reshape(value, 1, []);
    else
        items = {};
    end
end

% -- data locations ------------------------------------------------------------------------

function [dataset, entityLevels, warnings] = buildDataset(export, warnings)
    defNames = strings(1, 0);
    defs = {};
    locations = {};
    entityLevels = struct();
    used = strings(1, 0);
    localCount = 0;
    for item = nansen.internal.asCellOfStructs(nansen.internal.getField(export, "dataLocations", []))
        location = item{1};
        name = textOf(location, "name");
        [id, used] = uniqueName(identifier(name, "location", true), used);
        roots = {};
        rootKeys = strings(1, 0);   % dev's key of each root
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
            rootKeys(end + 1) = textOf(root, "key"); %#ok<AGROW>
        end
        if isempty(roots)
            warnings{end + 1} = sprintf("data location '%s': no root path, left out", name); %#ok<AGROW>
            continue
        end
        [roots, added] = localRoots(location, roots, rootKeys);
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
        localCount = localCount + added;
    end
    if localCount > 0
        warnings{end + 1} = sprintf("data locations: %d of dev's local root paths (the roots on the computer whose " + ...
            "preferences were read) are roots of the environment '%s'; on that computer, open the project in that environment", ...
            localCount, localEnvironment());
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

function [variables, dataset, warnings] = buildDataVariables(export, dataset, levels, legacyAdapters, warnings)
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
        own = [];   % one of the project's own adapters, imported (dev's code)
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
            case {"roiarray", "roigroup"}   % dev's ROI files: read by the ophys module
                adapter = "ophys.nansen_roi_array";
            case "roisignalarray"   % dev's ROI signals: named variables of one .mat file
                adapter = "mat";
            case "imagestack"   % dev's stacks of many file types: those the ophys module reads
                switch lower(fileType)
                    case {".tif", ".tiff"}
                        adapter = "ophys.tiff_stack";
                    case {".raw", ".bin", ".dat"}   % dev's own binary stack, or SciScan's: ophys.binary_stack reads both
                        adapter = "ophys.binary_stack";
                    case {".h5", ".hdf5"}
                        adapter = "ophys.hdf5_stack";
                    case ".npy"
                        adapter = "npy";
                    otherwise
                        adapter = "";
                end
            otherwise
                adapter = "";
                if hasKey(legacyAdapters, lower(adapterName))   % one of the project's own, imported (dev's code)
                    own = legacyAdapters(char(lower(adapterName)));
                    adapter = string(own.document.id);
                    if isfield(own, "reads") && ~isempty(own.reads)   % read as the class of dev's it is built on is:
                        at = find(own.reads(:, 1) == lower(fileType), 1);   % by the adapter here of that file type
                        if ~isempty(at)
                            adapter = own.reads(at, 2);
                        end
                    end
                end
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
        named = ismember(lower(adapterName), ["default", "", "roisignalarray"]) || (~isempty(own) && isfield(own, "base") ...
            && ismember(own.base, ["nansen.dataio.fileadapter.timeseries.RoiSignalArray", ...
            "nansen.module.ophys.twophoton.fileadapter.RoiSignalArray"]));   % (legacyadapters.NAMED_VARIABLE_BASES)
        if adapter == "mat" && named && ~isempty(regexp(legacyName, '^[A-Za-z][A-Za-z0-9_]*$', "once"))
            document.variableInFile = char(legacyName);   % dev loaded the variable of the data variable's name
        end
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
    subsets = {};
    for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(export, "tables", []))
        table = entry{1};
        label = textOf(table, "name");
        entityType = lower(textOf(table, "entityClass"));
        isMaster = nansen.internal.getField(table, "isMaster", true);
        if islogical(isMaster) && isscalar(isMaster) && ~isMaster
            subsets{end + 1} = table; %#ok<AGROW>   % a dev "filtered" table holds a subset of the master's rows: a view
            continue
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
        % dev's subject table variables, in core.subject when their type matches
        subject = struct();
        if entityType == "subject"
            known = ["DateOfBirth", "date_of_birth", "date"; "BiologicalSex", "sex", "string"; "Species", "species", "string"];
            for k = 1:size(known, 1)
                at = find(columnNames == known(k, 1), 1);
                if ~isempty(at) && columnTypes(at) == known(k, 3)
                    subject.(known(k, 1)) = known(k, 2);
                end
            end
        end
        subjectNames = string(struct2cell(subject))';
        extra = {};
        renames = struct();
        taken = [keyNames, attributes, "ignore", "description", subjectNames];
        for c = 1:numel(columnNames)
            column = columnNames(c);
            if isfield(idColumns, column) || isfield(notesColumns, column) || isfield(subject, column) ...
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
        if ~isempty(subjectNames)
            fragmentIds{end + 1} = 'core.subject'; %#ok<AGROW>
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
        legacyRows = nansen.internal.asCellOfStructs(table.rows);
        identities = cell(1, numel(legacyRows));   % per row, its identity, for the notes
        progressItems = listOf(nansen.internal.getField(table, "progress", {}));   % dev's Progress column
        progressRows = cellfun(@(p) double(p.row), progressItems);
        keptProgress = {};   % index in rows, key and dev's progress of the rows kept
        oddSexes = 0;
        for index = 1:numel(legacyRows)
            legacyRow = legacyRows{index};
            row = struct();
            for column = reshape(string(fieldnames(legacyRow)), 1, [])
                value = legacyRow.(column);
                if isfield(idColumns, column)
                    row.(idColumns.(column)) = value;
                elseif isfield(notesColumns, column)
                    row.(notesColumns.(column)) = value;
                elseif isfield(subject, column)
                    if column == "BiologicalSex" && (ischar(value) || isstring(value))
                        text = lower(strtrim(string(value)));
                        if ismember(text, ["", "n/a", "na"])
                            value = [];
                        elseif ismember(text, sexes())
                            value = char(text);
                        else
                            oddSexes = oddSexes + 1;   % kept as written
                        end
                    end
                    row.(subject.(column)) = value;
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
            identities{index} = identity;
            identityText = strjoin(identity, "/");
            if ismember(identityText, seen)
                warnings{end + 1} = sprintf("table '%s': %s appears twice; kept the first", label, identityText); %#ok<AGROW>
                continue
            end
            seen(end + 1) = identityText; %#ok<AGROW>
            at = find(progressRows == index - 1, 1, "last");
            if ~isempty(at)
                progressKey = struct();
                for k = 1:numel(keyNames)
                    progressKey.(keyNames(k)) = char(identity(k));
                end
                keptProgress{end + 1} = struct("index", numel(rows) + 1, "key", progressKey, "item", progressItems{at}); %#ok<AGROW>
            end
            keep = [keyNames, "ignore", "description", renamed, subjectNames];
            fields = string(fieldnames(row))';
            if any(~ismember(fields, keep))
                row = rmfield(row, cellstr(fields(~ismember(fields, keep))));
            end
            rows{end + 1} = row; %#ok<AGROW>
        end
        if oddSexes
            warnings{end + 1} = sprintf("table '%s': %d BiologicalSex value(s) not among %s; kept as written", ...
                label, oddSexes, strjoin(sexes(), ", ")); %#ok<AGROW>
        end
        if incomplete
            warnings{end + 1} = sprintf("table '%s': %d row(s) with no %s; left out", label, incomplete, ...
                strjoin(keyNames, " or ")); %#ok<AGROW>
        end
        [notes, warnings] = notesOf(table, identities, keyNames, label, warnings);
        % what the table variables and dev's column layout are matched with: each dev column's name here, the names
        % taken, and whether dev opened the table first
        names = struct();
        for column = columnNames
            if isfield(idColumns, column) && ismember(idColumns.(column), [keyNames, attributes])
                names.(column) = idColumns.(column);
            elseif isfield(notesColumns, column)
                names.(column) = notesColumns.(column);
            elseif isfield(derived, column) && ismember(derived.(column), attributes)
                names.(column) = derived.(column);
            end
        end
        for column = reshape(string(fieldnames(subject)), 1, [])
            names.(column) = subject.(column);
        end
        for column = reshape(string(fieldnames(renames)), 1, [])
            names.(column) = renames.(column);
        end
        isDefault = nansen.internal.getField(table, "isDefault", []);
        if ~(islogical(isDefault) && isscalar(isDefault))
            isDefault = [];
        end
        title = upper(extractBefore(entityType, 2)) + extractAfter(entityType, 1) + "s";
        tables{end + 1} = struct("entityType", char(entityType), "title", char(title), "key", {key}, ...
            "fragments", {fragmentIds}, "rows", {rows}, "notes", {notes}, ...
            "progress", struct("label", label, "rows", {keptProgress}), ...
            "layout", struct("label", label, "names", names, "taken", taken, "isDefault", isDefault)); %#ok<AGROW>
    end
    for entityType = declared(~ismember(declared, done))
        % a table to sync into, for entity types dev kept no table of
        title = upper(extractBefore(entityType, 2)) + extractAfter(entityType, 1) + "s";
        tables{end + 1} = struct("entityType", char(entityType), "title", char(title), ...
            "key", {keyOf(entityType, declared)}, "fragments", {{'core.notes'}}, "rows", {{}}, "notes", {{}}); %#ok<AGROW>
    end
    if ~isempty(tables)
        [~, order] = sort(cellfun(@(t) find(declared == t.entityType, 1), tables));
        tables = tables(order);
    end
    for i = 1:numel(subsets)
        [tables, warnings] = buildView(subsets{i}, tables, idColumns, warnings);
    end
end

function [tables, warnings] = buildView(table, tables, idColumns, warnings)
    % A dev filtered table as a view of its entity type: the keys of its rows, found in the master's
    label = textOf(table, "name");
    entityType = lower(textOf(table, "entityClass"));
    at = find(cellfun(@(t) string(t.entityType) == entityType, tables), 1);
    if isempty(at)
        shown = entityType;
        if shown == ""
            shown = "such";
        end
        warnings{end + 1} = sprintf("table '%s': the dataset has no %s entity type; left out", label, shown);
        return
    end
    target = tables{at};
    keyNames = string(target.key(:, 1))';
    keys = {};
    seen = strings(1, 0);
    unmatched = 0;
    for r = nansen.internal.asCellOfStructs(nansen.internal.getField(table, "rows", []))
        given = struct();
        for column = reshape(string(fieldnames(r{1})), 1, [])
            value = r{1}.(column);
            if isfield(idColumns, column) && ~isempty(value) && ismember(idColumns.(column), keyNames)
                given.(idColumns.(column)) = value;
            end
        end
        names = string(fieldnames(given))';
        if numel(names) == numel(keyNames)
            key = struct();
            for name = keyNames
                key.(name) = given.(name);
            end
        else   % a filtered table may hold only the session id: find the row of the master table it is
            found = {};
            for m = 1:numel(target.rows)
                row = target.rows{m};
                if ~isempty(names) && all(arrayfun(@(n) isfield(row, n) && isequal(string(row.(n)), string(given.(n))), names))
                    found{end + 1} = row; %#ok<AGROW>
                end
            end
            if numel(found) ~= 1
                unmatched = unmatched + 1;
                continue
            end
            key = struct();
            for name = keyNames
                key.(name) = found{1}.(name);
            end
        end
        id = nansen.internal.runKeyId(key);
        if ~ismember(id, seen)
            seen(end + 1) = id; %#ok<AGROW>
            keys{end + 1} = key; %#ok<AGROW>
        end
    end
    if unmatched
        warnings{end + 1} = sprintf("table '%s': %d row(s) not found in the %s table; left out of its view", label, unmatched, entityType);
    end
    view = struct("name", char(label), "description", char("Imported from the dev table " + label), "keys", {keys});
    isDefault = nansen.internal.getField(table, "isDefault", false);
    if islogical(isDefault) && isscalar(isDefault) && isDefault   % the table dev opened first: the view the table opens with
        view.default = true;
    end
    if ~isfield(target, "views")
        target.views = {};
    end
    target.views{end + 1} = view;
    tables{at} = target;
end

function [fragments, tables, methods_, warnings] = buildTableVariables(export, tables, fragments, warnings)
    % dev's table variables of the project (code/+<package>/+tablevariable/+<entity type>/<Name>.m) as columns of the
    % entity type, as columns.import brings them (nansen.Project.importColumn): a class (Name < TableVariable) is the
    % column dev's table holds, typed in, with the choices of its LIST_ALTERNATIVES (and the values the table holds
    % besides) and the yes/no default of its DEFAULT_VALUE; a function (value = Name(sessionObject)) makes it a
    % computed column, of a fragment and method of the name in snake case that calls dev's function, copied beside
    % it. The values the table holds are kept, and a column it did not hold is added. methods_ are the computed
    % columns' methods: document, and files (path under matlab/, and text). As Python's legacy._table_variables.
    methods_ = {};
    used = strings(1, 0);
    items = listOf(nansen.internal.getField(export, "tableVariables", {}));
    files = strings(1, numel(items));
    for i = 1:numel(items)
        files(i) = textOf(items{i}, "file");
    end
    [~, order] = sort(files);
    for i = reshape(order, 1, [])
        file = files(i);
        where = "table variable " + file;
        parts = split(file, "/");
        entityType = "";
        if numel(parts) >= 3 && parts(end - 2) == "+tablevariable" && startsWith(parts(end - 1), "+")
            entityType = lower(extractAfter(parts(end - 1), 1));
        end
        [~, name] = fileparts(file);
        name = string(name);
        at = find(cellfun(@(t) string(t.entityType) == entityType && isfield(t, "layout"), tables), 1);
        if isempty(at)
            shown = entityType;
            if shown == ""
                shown = "its";
            end
            warnings{end + 1} = sprintf("%s: dev kept no table of %s entities here; left out", where, shown); %#ok<AGROW>
            continue
        end
        table = tables{at};
        text = replace(string(nansen.internal.getField(items{i}, "text", "")), sprintf("\r\n"), newline);
        try
            shape = nansen.Project.columnCodeShape(text, name, ".m");
        catch err
            if ~isa(err, "nansen.NansenError")
                rethrow(err)
            end
            warnings{end + 1} = sprintf("%s: %s; left out", where, extractAfter(string(err.message), "] ")); %#ok<AGROW>
            continue
        end
        if ~ismember(shape.kind, ["devClass", "devFunction"])
            warnings{end + 1} = sprintf("%s: %s.m is not dev's table variable (a function value = %s(sessionObject), " + ...
                "or a class %s < TableVariable); left out", where, name, name, name); %#ok<AGROW>
            continue
        end
        layout = table.layout;
        fragmentId = "legacy." + entityType;
        own = find(cellfun(@(f) string(f.id) == fragmentId, fragments), 1);
        columnName = "";
        if isfield(layout.names, name)
            columnName = string(layout.names.(name));
        end
        entry = [];
        if ~isempty(own) && columnName ~= ""
            entry = find(cellfun(@(c) string(c.name) == columnName, fragments{own}.columns), 1);
        end
        if columnName ~= "" && isempty(entry)
            warnings{end + 1} = sprintf("%s: its column is %s here, which is not one of the project's own; left out", ...
                where, columnName); %#ok<AGROW>
            continue
        end
        [guessed, default] = nansen.Project.defaultType(shape.default);
        if isempty(entry)   % a column dev's table did not hold
            columnName = identifier(name, "column", false);
            if ismember(columnName, layout.taken)
                columnName = columnName + "_legacy";
            end
            layout.taken(end + 1) = columnName;
            layout.names.(name) = char(columnName);
            column = struct("name", char(columnName), "dataType", char(guessed));
            if guessed == "boolean"
                column.default = false;
            end
            if isempty(own)
                fragments{end + 1} = struct("schemaType", 'nansen.fragment', "schemaVersion", '0.1.0', ...
                    "id", char(fragmentId), "version", '1.0.0', ...
                    "title", char("Columns imported from the " + layout.label + " table"), "columns", {{}}); %#ok<AGROW>
                own = numel(fragments);
                table.fragments{end + 1} = char(fragmentId);
            end
            fragments{own}.columns{end + 1} = column;
            entry = numel(fragments{own}.columns);
        end
        column = fragments{own}.columns{entry};
        if string(column.dataType) == "boolean" && ~isempty(default)
            column.default = default;
        end
        fragments{own}.columns{entry} = column;
        table.layout = layout;
        tables{at} = table;
        if shape.kind == "devClass"
            if ~isempty(shape.choices) && string(column.dataType) == "string"
                extra = strings(1, 0);
                for r = 1:numel(table.rows)
                    value = nansen.internal.getField(table.rows{r}, columnName, []);
                    if (ischar(value) || isstring(value)) && ~ismember(string(value), [shape.choices, extra])
                        extra(end + 1) = string(value); %#ok<AGROW>
                    end
                end
                column.choices = cellstr([shape.choices, extra]);
                fragments{own}.columns{entry} = column;
                if ~isempty(extra)
                    warnings{end + 1} = sprintf("%s: the table's values %s are not among its LIST_ALTERNATIVES; " + ...
                        "added to the column's choices", where, strjoin(extra, ", ")); %#ok<AGROW>
                end
            end
            continue
        end
        methodId = string(nansen.Project.snakeCase(name));
        if isempty(regexp(methodId, "^[a-z][a-z0-9_]*$", "once"))
            warnings{end + 1} = sprintf("%s: '%s' cannot be the id of its column's method; left out", where, methodId); %#ok<AGROW>
            continue
        end
        [methodId, used] = uniqueName(methodId, used);
        fragments{own}.columns(entry) = [];
        if isempty(fragments{own}.columns)
            fragments(own) = [];
            table.fragments(strcmp(table.fragments, fragmentId)) = [];
        end
        fragmentEntry = nansen.internal.schemaEntry("nansen.fragment");
        fragments{end + 1} = struct("schemaType", 'nansen.fragment', "schemaVersion", char(fragmentEntry.version), ...
            "id", char(methodId), "version", '1.0.0', "title", char(name), "columns", {{column}}, ...
            "compute", struct("method", char(methodId))); %#ok<AGROW>
        table.fragments{end + 1} = char(methodId);
        tables{at} = table;
        methodEntry = nansen.internal.schemaEntry("nansen.method");
        document = struct("schemaType", 'nansen.method', "schemaVersion", char(methodEntry.version), "id", char(methodId), ...
            "version", '0.1.0', "title", char(name), "entityType", char(entityType), "batchMode", 'serial', ...
            "implementations", struct("matlab", char(methodId)), "options", struct("type", 'object', "properties", struct()), ...
            "description", char("Computes the column " + columnName + ", imported from " + name + ".m (dev's table variable " + name + ")"));
        nansen.checkDocument(document, ExpectedType="nansen.method");
        files_ = {struct("path", methodId + ".m", "text", nansen.Project.devColumnMethod(methodId, columnName, name + ".m")), ...
            struct("path", methodId + "_value.m", "text", nansen.Project.renameFunction(text, methodId + "_value"))};
        methods_{end + 1} = struct("document", document, "files", {files_}); %#ok<AGROW>
    end
end

function [fragments, tables, warnings] = buildLayouts(export, tables, fragments, warnings)
    % dev's column layout (metatable_column_settings: which columns its table showed, in which order, how wide and
    % with which labels) and its MetadataTable.ShowIgnoredEntries preference, on the views of each table dev kept: a
    % view of the whole table, of the master table's name, which the table opens with unless dev opened one of its
    % filtered tables first, and the views of its filtered tables. The labels are the titles of the project's own
    % columns. As Python's legacy._layouts.
    settings = listOf(nansen.internal.getField(export, "columnSettings", {}));
    settings = settings(cellfun(@isstruct, settings));
    preferences = nansen.internal.getField(export, "settings", struct());
    tablePreferences = nansen.internal.getField(preferences, "MetadataTable", struct());
    showIgnored = nansen.internal.getField(tablePreferences, "ShowIgnoredEntries", []);
    hideIgnored = islogical(showIgnored) && isscalar(showIgnored) && ~showIgnored;
    labelsLeft = strings(1, 0);
    for t = 1:numel(tables)
        if ~isfield(tables{t}, "layout")
            continue
        end
        table = tables{t};
        names = table.layout.names;
        mapped = zeros(1, 0);   % the settings of the variables the table has a column for
        for i = 1:numel(settings)
            variable = textOf(settings{i}, "variable");
            if isvarname(char(variable)) && isfield(names, variable)
                mapped(end + 1) = i; %#ok<AGROW>
            end
        end
        orders = inf(numel(mapped), 1);   % by their order, those without one last, else as listed
        hidden = strings(1, 0);
        widths = struct();
        for k = 1:numel(mapped)
            setting = settings{mapped(k)};
            column = string(names.(textOf(setting, "variable")));
            value = nansen.internal.getField(setting, "order", []);
            if isnumeric(value) && isscalar(value) && isfinite(value)
                orders(k) = double(value);
            end
            show = nansen.internal.getField(setting, "show", []);
            if islogical(show) && isscalar(show) && ~show && ~ismember(column, hidden)
                hidden(end + 1) = column; %#ok<AGROW>
            end
            width = nansen.internal.getField(setting, "width", []);
            if isnumeric(width) && isscalar(width) && isfinite(width) && width > 0
                widths.(column) = double(width);
            end
        end
        [~, byOrder] = sortrows([orders, (1:numel(mapped))']);
        shownOrder = strings(1, 0);
        for k = reshape(byOrder, 1, [])
            column = string(names.(textOf(settings{mapped(k)}, "variable")));
            if ~ismember(column, shownOrder)
                shownOrder(end + 1) = column; %#ok<AGROW>
            end
        end
        layout = struct();
        if ~isempty(hidden)
            layout.hiddenColumns = cellstr(hidden);
        end
        if ~isempty(shownOrder)
            layout.columnOrder = cellstr(shownOrder);
        end
        if ~isempty(fieldnames(widths))
            layout.columnWidths = widths;
        end
        if hideIgnored && ismember("core.notes", string(table.fragments))
            layout.filters = {struct("column", 'ignore', "op", 'is', "value", false)};
        end
        own = find(cellfun(@(f) ismember(string(f.id), string(table.fragments)), fragments));
        for k = 1:numel(mapped)
            variable = textOf(settings{mapped(k)}, "variable");
            label = strtrim(textOf(settings{mapped(k)}, "label"));
            if label == "" || label == variable
                continue
            end
            column = string(names.(variable));
            placed = false;
            for f = reshape(own, 1, [])
                at = find(cellfun(@(c) string(c.name) == column, fragments{f}.columns), 1);
                if ~isempty(at)
                    fragments{f}.columns{at}.title = char(label);
                    placed = true;
                end
            end
            if ~placed
                labelsLeft(end + 1) = variable + " (" + label + ")"; %#ok<AGROW>
            end
        end
        if isempty(fieldnames(layout))
            continue
        end
        views = nansen.internal.getField(table, "views", {});
        anyDefault = false;
        taken = false;
        for v = 1:numel(views)
            for field = reshape(string(fieldnames(layout)), 1, [])
                views{v}.(field) = layout.(field);
            end
            anyDefault = anyDefault || (isfield(views{v}, "default") && isequal(views{v}.default, true));
            taken = taken || string(views{v}.name) == table.layout.label;
        end
        name = table.layout.label;
        if taken
            name = name + " (all)";
        end
        master = struct("name", char(name), ...
            "description", char("dev's table " + table.layout.label + ", with its columns as dev showed them"));
        for field = reshape(string(fieldnames(layout)), 1, [])
            master.(field) = layout.(field);
        end
        if ~isequal(table.layout.isDefault, false) && ~anyDefault
            master.default = true;
        end
        table.views = [{master}, reshape(views, 1, [])];
        tables{t} = table;
    end
    if ~isempty(labelsLeft)
        warnings{end + 1} = sprintf("dev's column labels of %s are not carried over: those columns are keys, dataset " + ...
            "attributes or a module's, which keep their own titles", strjoin(unique(labelsLeft, "stable"), ", "));
    end
end

function [notes, warnings] = notesOf(table, identities, keyNames, label, warnings)
    % The Notebook column's notes, on the entity of their row, in the order they were written
    notes = {};
    times = strings(1, 0);
    orphans = 0;
    untimed = 0;
    for item = nansen.internal.asCellOfStructs(nansen.internal.getField(table, "notes", []))
        note = item{1};
        index = note.row + 1;
        if index > numel(identities) || isempty(identities{index})
            orphans = orphans + 1;
            continue
        end
        if isempty(note.createdAt)
            untimed = untimed + 1;
            continue
        end
        type = lower(string(note.type));
        if ~ismember(type, nansen.Notebook.Types)
            warnings{end + 1} = sprintf("table '%s': a note of type '%s' is imported as informal", label, note.type); %#ok<AGROW>
            type = "informal";
        end
        key = struct();
        for k = 1:numel(keyNames)
            key.(keyNames(k)) = char(identities{index}(k));
        end
        notes{end + 1} = struct("key", key, "createdAt", char(note.createdAt), "author", char(note.author), ...
            "type", char(type), "title", char(note.title), "text", char(note.text)); %#ok<AGROW>
        times(end + 1) = string(note.createdAt); %#ok<AGROW>
    end
    if orphans
        warnings{end + 1} = sprintf("table '%s': %d note(s) on rows that were left out; left out", label, orphans);
    end
    if untimed
        warnings{end + 1} = sprintf("table '%s': %d note(s) with no time; left out", label, untimed);
    end
    [~, order] = sort(times);   % stable: notes of the same second keep their order
    notes = notes(order);
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

function [roots, added] = localRoots(location, roots, rootKeys)
    % dev's local root paths of a location (its LocalRootPathManager's, for the computer dev ran on: by the key of the
    % root they stand for) that differ from the root, added to the roots as roots of the environment dev-local; how
    % many. A key the location has no root of is passed over, as dev did.
    added = 0;
    for item = nansen.internal.asCellOfStructs(nansen.internal.getField(location, "localRootPaths", []))
        root = item{1};
        value = textOf(root, "value");
        k = find(rootKeys == textOf(root, "key"), 1);
        if value == "" || isempty(k) || value == string(roots{k}.path)
            continue
        end
        base = string(roots{k}.identifier) + "-" + localEnvironment();
        rootId = base;
        n = 2;
        while any(cellfun(@(r) string(r.identifier) == rootId, roots))
            rootId = base + "-" + n;
            n = n + 1;
        end
        entry = struct("identifier", char(rootId), "path", char(value), "environment", char(localEnvironment()));
        if textOf(root, "diskName") ~= ""
            entry.volumeName = char(textOf(root, "diskName"));
        end
        roots{end + 1} = entry; %#ok<AGROW>
        added = added + 1;
    end
end

function name = localEnvironment()
    % The DSM environment of dev's local root paths (dev keeps them per computer, without naming it)
    name = "dev-local";
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

function values = sexes()
    % core.subject's choices for sex
    values = ["female", "male", "not detected"];
end
