function report = convert(export, folder)
%convert Write a project into an empty folder from a nansen.legacyExport document
%
%   report = nansen.legacy.convert(export, folder) takes the export as a
%   struct (from nansen.legacy.exportProject, or decoded from its JSON file)
%   and returns a struct with fields project, rows, notes, dataVariables,
%   fileAdapters, methods, presets, pipelines, tasks (how many queued),
%   history (how many finished), runs (how many), settings (dev's app
%   preferences as settings.save takes them) and warnings. The rules are
%   those of the Python nansen.legacy module, and the cases in
%   conformance/legacy hold the two to the same result:
%
%   - data locations, with their roots, folder levels and metadata rules,
%     become a DSM config;
%   - master tables of sessions and subjects become entity tables, with
%     Ignore and Description in core.notes and other columns in a
%     legacy.<entityType> fragment; an entity type the dataset has but dev
%     kept no table of gets an empty table with core.notes;
%   - file path settings become data variables when their file adapter has
%     a built-in equivalent;
%   - the notes of a Notebook column go into the entity type's notebook;
%   - filtered (non-master) tables become views of their entity type, and
%     dev's column layout (shown, order, widths) and ShowIgnoredEntries go
%     onto them and onto a view of each whole table; the labels become the
%     titles of the project's own columns;
%   - the project's own table variables (tableVariables) come in as
%     columns.import brings them: a class as the column, with its choices,
%     a function as a computed column filled by dev's function;
%   - the project's own session methods (sessionMethods) become methods of
%     sessions that run dev's code unchanged (nansen.legacy.SessionShim),
%     and pipeline tasks that call them become steps;
%   - the project's own file adapters (fileAdapters) become file adapters
%     that run dev's code unchanged (nansen.legacy.FileAdapterShim), and the
%     variables read with them data variables;
%   - the option presets users made become presets of the methods here,
%     and dev's chosen default preset the method's preferred one;
%   - the queued tasks of dev's task list become queued tasks, on hold, in
%     dev's order; the tasks of its history become finished tasks of the
%     queue (completed, failed or cancelled), with dev's log (Diary) and
%     error (ErrorStack); its completed tasks and the finished tasks of the
%     Progress column go into the run journal, and the column's pipeline
%     into core.pipeline;
%   - dev's local root paths become roots of the DSM environment dev-local.
%
%   Whatever cannot be mapped is left out and named in report.warnings.
    arguments
        export (1,1) struct
        folder (1,1) string
    end
    export = nansen.internal.jsonRoundTrip(export);
    export = nansen.checkDocument(export, ExpectedType="nansen.legacyExport", Source="legacy export");
    plan = nansen.legacy.plan(export);
    if isfolder(folder) && numel(dir(folder)) > 2
        nansen.internal.throwError("folder-not-empty", "%s is not empty", folder)
    end
    if ~isfolder(folder)
        mkdir(folder);
    end
    nansen.internal.writeJson(fullfile(folder, "dataset.dsm.json"), plan.dataset)
    project = nansen.Project.create(folder, plan.name, Title=plan.title, Dataset="dataset.dsm.json", ...
        Description=plan.description);
    nansen.legacy.writeFileAdapters(folder, plan.fileAdapters);   % before the modules, whose adding reads the adapters again
    for module = plan.modules
        project.addModule(module);
    end
    for i = 1:numel(plan.fragments)
        project.addFragment(plan.fragments{i});
    end
    rows = struct();
    notes = struct();
    for i = 1:numel(plan.tables)
        spec = plan.tables{i};
        key = nansen.Column.empty(1, 0);
        for k = 1:size(spec.key, 1)
            key(end + 1) = nansen.Column(spec.key{k, 1}, spec.key{k, 2}); %#ok<AGROW>
        end
        table = project.addEntityType(spec.entityType, key, Fragments=reshape(string(spec.fragments), 1, []), Title=spec.title);
        for r = 1:numel(spec.rows)
            table.addRow(spec.rows{r});
        end
        table.write();
        rows.(spec.entityType) = numel(spec.rows);
        for v = 1:numel(nansen.internal.getField(spec, "views", {}))
            project.views(spec.entityType).save(spec.views{v});
        end
        if ~isempty(spec.notes)
            notebook = project.notebook(spec.entityType);
            for n = 1:numel(spec.notes)
                note = spec.notes{n};
                notebook.add(note.key, note.text, Title=note.title, Type=note.type, Author=note.author, ...
                    CreatedAt=note.createdAt);
            end
            notes.(spec.entityType) = numel(spec.notes);
        end
    end
    names = {};
    for i = 1:numel(plan.dataVariables)
        project.addDataVariable(plan.dataVariables{i});
        names{end + 1} = plan.dataVariables{i}.name; %#ok<AGROW>
    end
    nansen.legacy.writeSessionMethods(folder, plan.methods);
    for i = 1:numel(plan.columnMethods)   % the methods of dev's table variable functions, with dev's function
        entry = plan.columnMethods{i};
        for k = 1:numel(entry.files)
            if ~isfolder(fullfile(folder, "matlab"))
                mkdir(fullfile(folder, "matlab"));
            end
            nansen.internal.writeText(fullfile(folder, "matlab", entry.files{k}.path), entry.files{k}.text);
        end
        if ~isfolder(fullfile(folder, "methods"))
            mkdir(fullfile(folder, "methods"));
        end
        nansen.internal.writeJson(fullfile(folder, "methods", string(entry.document.id) + ".method.nansen.json"), entry.document)
    end
    if ~isempty(plan.columnMethods)
        rehash   % new files in a folder already on the path are seen at once
    end
    methodIds = cellfun(@(m) m.document.id, [plan.methods, plan.columnMethods], UniformOutput=false);
    warnings = plan.warnings;
    presets = {};
    for i = 1:numel(plan.presets)
        preset = plan.presets{i};
        method = project.method(preset.method);
        where = sprintf("option preset '%s' of %s", preset.name, method.Id);
        [values, warnings] = fitting(method, preset.values, where, warnings);
        project.savePreset(method.Id, preset.name, values, preset.description);
        presets{end + 1} = char(method.Id + "/" + preset.name); %#ok<AGROW>
    end
    for i = 1:numel(plan.preferredPresets)
        project.setPreferredPreset(plan.preferredPresets{i}.method, plan.preferredPresets{i}.preset);
    end
    pipelineIds = {};
    for i = 1:numel(plan.pipelines)
        project.savePipeline(plan.pipelines{i});
        pipelineIds{end + 1} = plan.pipelines{i}.id; %#ok<AGROW>
    end
    [tasks, history, warnings] = writeTasks(project, plan.tasks, warnings);
    writeRuns(project, plan.runs);
    adapterIds = cellfun(@(a) a.document.id, plan.fileAdapters, UniformOutput=false);
    report = struct("project", char(folder), "rows", rows, "notes", notes, "dataVariables", {names}, ...
        "fileAdapters", {adapterIds}, "methods", {methodIds}, "presets", {presets}, "pipelines", {pipelineIds}, ...
        "tasks", tasks, "history", history, "runs", numel(plan.runs), "settings", plan.settings, "warnings", {warnings});
end

function [kept, warnings] = fitting(method, values, where, warnings)
    % The values of the options the method's options schema has, or does not name, less those of a value it refuses
    declared = nansen.internal.getField(method.optionsSchema(), "properties", struct());
    kept = struct();
    for name = reshape(string(fieldnames(values)), 1, [])
        if isfield(declared, name) && ...
                ~isempty(nansen.internal.schemaValidationErrors(nansen.internal.jsonRoundTrip(values.(name)), declared.(name)))
            warnings{end + 1} = sprintf("%s: option '%s' does not fit the method's options; left out", where, name); %#ok<AGROW>
            continue
        end
        kept.(name) = values.(name);
    end
end

function [count, finished, warnings] = writeTasks(project, planned, warnings)
    % dev's queued tasks as queued tasks on hold, in dev's queue order, so nothing runs before it is released; and the
    % tasks of its history as finished tasks (completed, failed or cancelled), with dev's log (Diary) as the task's log
    % and dev's error (ErrorStack), which can be retried. count and finished are how many of each.
    count = 0;
    finished = 0;
    folder = fullfile(project.Folder, "tasks");
    for i = 1:numel(planned)
        item = planned{i};
        method = project.method(item.method);
        status = string(nansen.internal.getField(item, "status", ""));
        kind = "queued";
        if status ~= ""
            kind = "finished";
        end
        where = sprintf("%s task '%s' (%s)", kind, item.name, method.Id);
        if ~method.Queueable
            warnings{end + 1} = sprintf("%s: %s cannot run as a background task; left out", where, method.Id); %#ok<AGROW>
            continue
        end
        base = struct();   % dev's options over its preset's
        if isfield(item, "preset")
            base = project.preset(method.Id, item.preset);
        end
        [values, warnings] = fitting(method, item.values, where, warnings);
        values = method.resolveOptions(nansen.internal.mergeStructs(base, values));
        optionsEntry = struct("values", values);
        if isfield(item, "preset")
            optionsEntry.preset = char(item.preset);
        end
        createdAt = char(nansen.internal.timestamp());
        if isfield(item, "createdAt")
            createdAt = char(item.createdAt);
        elseif isfield(item, "finishedAt")
            createdAt = char(item.finishedAt);
        end
        references = cellfun(@(key) struct("entityType", 'session', "key", key), item.entities, UniformOutput=false);
        entry = nansen.internal.schemaEntry("nansen.task");
        progress = 0;
        if status == "completed"
            progress = 1;
        end
        taskStatus = 'queued';
        if status ~= ""
            taskStatus = char(status);
        end
        task = struct("schemaType", 'nansen.task', "schemaVersion", char(entry.version), ...
            "id", char(nansen.internal.uuid4()), ...
            "method", struct("id", char(method.Id), "version", char(method.Version)), ...
            "entities", {references}, "options", optionsEntry, "status", taskStatus, "createdAt", createdAt, ...
            "progress", progress);
        languages = string(method.Languages);
        if isscalar(languages)   % only that language's worker takes it
            task.language = char(languages);
        end
        if status ~= ""
            for field = ["startedAt", "finishedAt"]
                if isfield(item, field)
                    task.(field) = char(item.(field));
                end
            end
            if isfield(item, "log")
                task.log = char("tasks/" + string(task.id) + ".log");
            end
            if isfield(item, "error")
                task.error = item.error;
            end
        else
            task.order = count;
            task.onHold = true;
        end
        if isfield(item, "comment")
            task.comment = char(item.comment);
        end
        task = nansen.checkDocument(task, ExpectedType="nansen.task");
        if ~isfolder(folder)
            mkdir(folder);
        end
        if isfield(task, "log")
            nansen.internal.writeText(fullfile(project.Folder, task.log), string(item.log));
        end
        nansen.internal.writeJson(fullfile(folder, string(task.id) + ".task.nansen.json"), task)
        if status ~= ""
            finished = finished + 1;
        else
            count = count + 1;
        end
    end
end

function writeRuns(project, planned)
    % What dev recorded as done (its task history and Progress column) as lines of the run journal
    if isempty(planned)
        return
    end
    entry = nansen.internal.schemaEntry("nansen.run");
    text = "";
    for i = 1:numel(planned)
        run = planned{i};
        line = struct("schemaType", 'nansen.run', "schemaVersion", char(entry.version), ...
            "method", struct("id", char(run.method), "version", char(project.method(run.method).Version)), ...
            "key", run.key, "finishedAt", char(run.finishedAt));
        nansen.checkDocument(line, ExpectedType="nansen.run");
        text = text + string(jsonencode(line)) + newline;
    end
    folder = fullfile(project.Folder, "runs");
    if ~isfolder(folder)
        mkdir(folder);
    end
    fid = fopen(fullfile(folder, "session.runs.jsonl"), "a", "n", "UTF-8");
    fwrite(fid, char(text), "char");
    fclose(fid);
end
