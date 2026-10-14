function report = convert(export, folder)
%convert Write a project into an empty folder from a nansen.legacyExport document
%
%   report = nansen.legacy.convert(export, folder) takes the export as a
%   struct (from nansen.legacy.exportProject, or decoded from its JSON file)
%   and returns a struct with fields project, rows, dataVariables and
%   warnings. The rules are those of the Python nansen.legacy module, and
%   the cases in conformance/legacy hold the two to the same result:
%
%   - data locations, with their roots, folder levels and metadata rules,
%     become a DSM config;
%   - master tables of sessions and subjects become entity tables, with
%     Ignore and Description in core.notes and other columns in a
%     legacy.<entityType> fragment; an entity type the dataset has but dev
%     kept no table of gets an empty table with core.notes;
%   - file path settings become data variables when their file adapter has
%     a built-in equivalent;
%   - the notes of a Notebook column go into the entity type's notebook.
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
    project.addModule("core");
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
    report = struct("project", char(folder), "rows", rows, "notes", notes, "dataVariables", {names}, ...
        "warnings", {plan.warnings});
end
