classdef Project < handle
%Project A project folder (docs/reference/project-layout.md)
%
%   project = nansen.Project.create(folder, name) makes a new project and
%   project = nansen.Project.open(folder) opens one. Nothing records a
%   "current" project: code that needs a project is given one.

    properties (SetAccess = private)
        Folder (1,1) string
        Document struct
        % The environment (machine) whose root paths to use; "" means the dataset's preference
        Environment (1,1) string = ""
        % Data read by load, kept until its file changes; dev's DataCache, but this project's own
        DataCache
    end

    properties (Access = private)
        DatasetCache = []
        AdapterCache = []
        ModuleCache = []
    end

    properties (Dependent)
        Name
        Title
        EntityTypes
    end

    properties (Constant)
        ProjectFile = "project.nansen.json"
    end

    methods
        function obj = Project(folder, document, environment)
            %Project Wrap a folder and its decoded project document; use create or open instead
            arguments
                folder (1,1) string
                document (1,1) struct
                environment (1,1) string = ""
            end
            obj.Folder = folder;
            obj.Environment = environment;
            obj.DataCache = nansen.DataCache();   % here, not as a default: a handle default would be shared
            document.entityTypes = nansen.internal.asCellOfStructs(document.entityTypes);
            obj.Document = document;
        end

        function name = get.Name(obj)
            name = string(obj.Document.name);
        end

        function title = get.Title(obj)
            title = string(nansen.internal.getField(obj.Document, "title", obj.Document.name));
        end

        function names = get.EntityTypes(obj)
            names = string(cellfun(@(e) e.name, obj.Document.entityTypes, UniformOutput=false));
            names = reshape(names, 1, []);
        end

        function entry = entityType(obj, name)
            %entityType The entity type's entry in the project file
            match = obj.EntityTypes == name;
            if ~any(match)
                nansen.internal.throwError("unknown-entity-type", ...
                    "project '%s' has no entity type '%s'", obj.Name, name)
            end
            entry = obj.Document.entityTypes{find(match, 1)};
        end

        function path = fragmentPath(obj, fragmentId)
            path = fullfile(obj.Folder, "fragments", fragmentId + ".fragment.nansen.json");
        end

        function fragment = fragment(obj, fragmentId)
            %fragment A fragment from the project's fragments/ folder, else from its modules
            path = obj.fragmentPath(fragmentId);
            if isfile(path)
                fragment = nansen.Fragment.read(path);
                return
            end
            for module = obj.modules()
                for document = module.fragmentDocuments()
                    if string(document{1}.id) == string(fragmentId)
                        fragment = nansen.Fragment(document{1});
                        return
                    end
                end
            end
            nansen.internal.throwError("unknown-fragment", "fragment '%s' is not defined (%s, or in a module)", fragmentId, path)
        end

        function found = fragments(obj)
            %fragments Every fragment the project can use: its own, then its modules' (a cell row of nansen.Fragment)
            found = {};
            ids = strings(1, 0);
            folder = fullfile(obj.Folder, "fragments");
            if isfolder(folder)
                listing = dir(fullfile(folder, "*.fragment.nansen.json"));
                for name = sort(string({listing.name}))
                    fragment = nansen.Fragment.read(fullfile(folder, name));
                    if ~ismember(fragment.Id, ids)
                        found{end + 1} = fragment; %#ok<AGROW>
                        ids(end + 1) = fragment.Id; %#ok<AGROW>
                    end
                end
            end
            for module = obj.modules()
                for document = module.fragmentDocuments()
                    if ~ismember(string(document{1}.id), ids)
                        found{end + 1} = nansen.Fragment(document{1}); %#ok<AGROW>
                        ids(end + 1) = string(document{1}.id); %#ok<AGROW>
                    end
                end
            end
        end

        function path = tablePath(obj, entityType)
            path = fullfile(obj.Folder, "tables", entityType + ".table.nansen.json");
        end

        function table = table(obj, entityType)
            %table Read an entity type's table and check it against the entity type's fragments
            entry = obj.entityType(entityType);
            path = obj.tablePath(entityType);
            table = nansen.EntityTable.read(path);
            if table.EntityType ~= entityType
                nansen.internal.throwError("invalid-table-spec", "%s is a table of '%s'", path, table.EntityType)
            end
            fragmentIds = reshape(string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {}))), 1, []);
            fragments = arrayfun(@(id) obj.fragment(id), fragmentIds, UniformOutput=false);
            nansen.Project.checkFragments(table, fragments)
            for i = 1:numel(fragments)
                for name = reshape(string(fieldnames(fragments{i}.Defaults)), 1, [])
                    table.Defaults.(name) = fragments{i}.Defaults.(name);
                end
            end
        end

        function table = addEntityType(obj, name, key, options)
            %addEntityType Declare an entity type and write its empty table
            %
            %   The table has the key columns, then each fragment's columns.
            %   Without key columns (or with []), the key comes from the
            %   dataset: the identity of the entity's ancestors and its own.
            arguments
                obj
                name (1,1) string
                key = []
                options.Fragments (1,:) string = string.empty(1, 0)
                options.Title (1,1) string = ""
            end
            if ismember(name, obj.EntityTypes)
                error("nansen:Project:EntityTypeExists", "Entity type '%s' already exists", name)
            end
            if isempty(key)
                dataset = obj.requireDataset();
                if ~ismember(name, dataset.entityTypes())
                    nansen.internal.throwError("unknown-entity-type", "the dataset has no entity type '%s'", name)
                end
                key = dataset.keyColumns(name);
            end
            fragments = arrayfun(@(id) obj.fragment(id), options.Fragments, UniformOutput=false);
            table = nansen.EntityTable(name, [key.Name], key, File=name + ".csv");
            for i = 1:numel(fragments)
                table.addColumns(fragments{i}.Columns, fragments{i}.Defaults, fragments{i}.Id, fragments{i}.Version)
            end
            entry = struct("name", char(name));
            if options.Title ~= ""
                entry.title = char(options.Title);
            end
            if ~isempty(options.Fragments)
                entry.fragments = cellstr(options.Fragments);
            end
            document = obj.Document;
            document.entityTypes{end + 1} = entry;
            obj.writeDocument(document)
            table.write(obj.tablePath(name))
        end

        % -- dataset and entities -----------------------------------------------------

        function dataset = dataset(obj)
            %dataset The project's nansen.Dataset, or [] when the project has none
            dataset = [];
            if ~isfield(obj.Document, "dataset")
                return
            end
            if isempty(obj.DatasetCache)
                obj.DatasetCache = nansen.Dataset.load(fullfile(obj.Folder, obj.Document.dataset), obj.Environment);
            end
            dataset = obj.DatasetCache;
        end

        function dataset = setDataset(obj, source)
            %setDataset Copy a DSM config into the project as dataset.dsm.json (relative roots made absolute) and use it
            arguments
                obj
                source (1,1) string
            end
            if isfield(obj.Document, "dataset")
                nansen.internal.throwError("dataset-exists", "project '%s' already has a dataset", obj.Name)
            end
            target = fullfile(obj.Folder, "dataset.dsm.json");
            nansen.internal.copyDataset(source, target);
            document = obj.Document;
            document.dataset = 'dataset.dsm.json';
            obj.DatasetCache = [];
            previous = obj.Document;
            obj.Document = document;
            try
                dataset = obj.requireDataset();
            catch err
                obj.Document = previous;
                obj.DatasetCache = [];
                delete(target);
                rethrow(err)
            end
            obj.writeDocument(document);
        end

        function dataset = setRoot(obj, dataLocation, path, options)
            %setRoot Say where a data location is: a given root, or the location in this machine's environment or another
            %
            %   With RootStoragePath, that root gets the new path and nothing else
            %   changes. Otherwise the root the location uses in the environment
            %   (Environment, default: the active one, else this machine's host
            %   name) gets it, or a root is added for the environment. When the
            %   environment is not the active one, it becomes active on this
            %   machine (the DSM config's .local.json overlay), and every other
            %   location that would have no root there gets one at the path it
            %   uses now. Only those values change in the config's text, as in
            %   Python's Project.set_root.
            arguments
                obj
                dataLocation (1,1) string
                path (1,1) string
                options.Environment (1,1) string = ""
                options.RootStoragePath (1,1) string = ""
            end
            dataset = obj.requireDataset();
            configPath = fullfile(obj.Folder, obj.Document.dataset);
            text = nansen.internal.readText(configPath);
            config = jsondecode(char(text));
            locations = nansen.internal.asCellOfStructs(nansen.internal.getField(config, "dataLocations", []));
            ids = string(cellfun(@(l) l.identifier, locations, UniformOutput=false));
            index = find(ids == dataLocation, 1);
            if isempty(index)
                nansen.internal.throwError("unknown-location", "the dataset has no data location '%s'", dataLocation)
            end
            roots = rootsOf(locations{index});
            pointer = sprintf("/dataLocations/%d/filesystemSource/rootStoragePaths", index - 1);
            if options.RootStoragePath ~= ""
                j = find(string(cellfun(@(r) r.identifier, roots, UniformOutput=false)) == options.RootStoragePath, 1);
                if isempty(j)
                    nansen.internal.throwError("unknown-location", "'%s' has no root '%s'", dataLocation, options.RootStoragePath)
                end
                text = nansen.internal.JsonText.replace(text, pointer + "/" + (j - 1) + "/path", path);
                nansen.internal.writeText(configPath, text);
                obj.DatasetCache = [];
                dataset = obj.requireDataset();
                return
            end
            active = dataset.Environment;
            target = options.Environment;
            if target == ""
                target = active;
            end
            environments = string(cellfun(@(r) string(nansen.internal.getField(r, "environment", "")), roots, UniformOutput=false));
            if target ~= ""
                match = find(environments == target, 1);
            else
                match = find(environments == "", 1);
                if isempty(match)
                    target = nansen.Project.defaultEnvironment();
                end
            end
            if ~isempty(match)
                text = nansen.internal.JsonText.replace(text, pointer + "/" + (match - 1) + "/path", path);
            else
                text = nansen.internal.JsonText.append(text, pointer, struct("identifier", char(rootIdentifier(target, roots)), ...
                    "path", char(path), "environment", char(target)));
            end
            if target ~= active
                current = dataset.roots();
                for i = 1:numel(locations)
                    others = rootsOf(locations{i});
                    otherEnvironments = string(cellfun(@(r) string(nansen.internal.getField(r, "environment", "")), others, UniformOutput=false));
                    if i == index || any(otherEnvironments == "" | otherEnvironments == target)
                        continue
                    end
                    used = current([current.DataLocation] == ids(i));
                    if ~isempty(used)   % keep it working where it is
                        text = nansen.internal.JsonText.append(text, sprintf("/dataLocations/%d/filesystemSource/rootStoragePaths", i - 1), ...
                            struct("identifier", char(rootIdentifier(target, others)), ...
                            "path", char(replace(used(1).Path, "\", "/")), "environment", char(target)));
                    end
                end
                setEnvironment(configPath, target);
            end
            nansen.internal.writeText(configPath, text);
            obj.DatasetCache = [];
            dataset = obj.requireDataset();
        end

        function added = addDatasetEntityTypes(obj, options)
            %addDatasetEntityTypes Add every entity type of the dataset the project does not have yet; returns their names
            arguments
                obj
                options.Fragments (1,:) string = string.empty(1, 0)
            end
            added = strings(1, 0);
            for name = reshape(string(obj.requireDataset().entityTypes()), 1, [])
                if ~ismember(name, obj.EntityTypes)
                    words = split(replace(name, "_", " "), " ")';
                    title = join(upper(extractBefore(words, 2)) + extractAfter(words, 1), " ") + "s";
                    obj.addEntityType(name, [], Fragments=options.Fragments, Title=title);
                    added(end + 1) = name; %#ok<AGROW>
                end
            end
        end

        function dataset = requireDataset(obj)
            dataset = obj.dataset();
            if isempty(dataset)
                nansen.internal.throwError("no-dataset", "project '%s' has no dataset", obj.Name)
            end
        end

        function path = notebookPath(obj, entityType)
            path = string(fullfile(obj.Folder, "notes", entityType + ".notebook.nansen.json"));
        end

        function notebook = notebook(obj, entityType)
            %notebook The notes on an entity type's entities (an nansen.Notebook)
            arguments
                obj
                entityType (1,1) string
            end
            obj.entityType(entityType);
            notebook = nansen.Notebook(obj.notebookPath(entityType), entityType, obj.table(entityType).Key);
        end

        function path = scanPath(obj)
            path = string(fullfile(obj.Folder, "cache", "scan.nansen.json"));
        end

        function result = scan(obj, listing, options)
            %scan Walk the data locations (or a given dsm.Listing) and keep the result in cache/
            arguments
                obj
                listing = []
                options.Registry = []
                options.Save (1,1) logical = true
            end
            dataset = obj.requireDataset();
            if isempty(options.Registry)
                result = dataset.scan(listing);
            else
                result = dataset.scan(listing, options.Registry);
            end
            if options.Save
                result.write(obj.scanPath())
            end
        end

        function result = lastScan(obj)
            result = [];
            if isfile(obj.scanPath())
                result = nansen.Scan.read(obj.scanPath());
            end
        end

        function entities = entities(obj, entityType, scan)
            %entities Table rows joined with the records of the last (or given) scan: a cell row of nansen.Entity
            arguments
                obj
                entityType (1,1) string
                scan = []
            end
            table = obj.table(entityType);
            dataset = obj.dataset();
            records = {};
            recordKey = @nansen.Project.recordKeyOf;
            if ~isempty(dataset) && ismember(entityType, dataset.entityTypes())
                keyColumns = dataset.keyColumns(entityType);
                expected = [keyColumns.Name];
                if ~isequal(expected, table.Key)
                    nansen.internal.throwError("key-mismatch", "table key %s differs from the dataset identity %s", ...
                        strjoin(table.Key, ","), strjoin(expected, ","))
                end
                if isempty(scan)
                    scan = obj.lastScan();
                end
                if ~isempty(scan)
                    records = scan.recordsOf(entityType);
                end
                recordKey = @(record) dataset.recordKey(record);
            end
            entities = nansen.internal.joinEntities(entityType, table.Key, records, table, recordKey);
            entities = cellfun(@(e) e.withProject(obj), entities, UniformOutput=false);
        end

        function entity = entity(obj, entityType, key, scan)
            %entity The entity whose key matches the given fields (a struct)
            arguments
                obj
                entityType (1,1) string
                key (1,1) struct
                scan = []
            end
            for candidate = obj.entities(entityType, scan)
                matches = true;
                for name = reshape(string(fieldnames(key)), 1, [])
                    value = nansen.internal.getField(candidate{1}.Key, name, []);
                    matches = matches && isequal(string(value), string(key.(name)));
                end
                if matches
                    entity = candidate{1};
                    return
                end
            end
            nansen.internal.throwError("unknown-entity", "no %s with the given key", entityType)
        end

        function added = sync(obj, entityType, scan)
            %sync Add a table row for every entity found in the stores but not in the table; returns their keys
            arguments
                obj
                entityType (1,1) string
                scan = []
            end
            table = obj.table(entityType);
            added = {};
            for candidate = obj.entities(entityType, scan)
                entity = candidate{1};
                if entity.inTable() || any(cellfun(@(i) string(i.code) == "incomplete-key", entity.Issues))
                    continue
                end
                added{end + 1} = entity.Key; %#ok<AGROW>
            end
            if ~isempty(added)
                table.addRows(added);   % at once: one row at a time grows the table quadratically
                table.write()
            end
        end

        % -- data variables and file adapters ------------------------------------------

        function registry = adapters(obj)
            %adapters Built-in file adapters, those declared in file-adapters/ (code in matlab/), then the modules'
            if isempty(obj.AdapterCache)
                registry = nansen.AdapterRegistry();
                modules = obj.modules();
                for i = numel(modules):-1:1
                    for document = modules(i).fileAdapterDocuments()
                        registry.declare(document{1}, modules(i).MatlabRoot);
                    end
                end
                folder = fullfile(obj.Folder, "file-adapters");
                if isfolder(folder)
                    listing = dir(fullfile(folder, "*.fileAdapter.nansen.json"));
                    for name = sort(string({listing.name}))
                        registry.declare(nansen.readDocument(fullfile(folder, name), ...
                            ExpectedType="nansen.fileAdapter"), fullfile(obj.Folder, "matlab"));
                    end
                end
                obj.AdapterCache = registry;
            end
            registry = obj.AdapterCache;
        end

        % -- modules, methods and presets ------------------------------------------------

        function modules = modules(obj)
            %modules The project's modules, in order of precedence: a row of nansen.Module
            if isempty(obj.ModuleCache)
                modules = nansen.Module.empty(1, 0);
                for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(obj.Document, "modules", []))
                    modules(end + 1) = nansen.Module.resolve(entry{1}, obj.Folder); %#ok<AGROW>
                end
                obj.ModuleCache = {modules};
            end
            modules = obj.ModuleCache{1};
        end

        function module = addModule(obj, moduleId, modulePath)
            %addModule List a module in the project file, after checking it can be found
            arguments
                obj
                moduleId (1,1) string
                modulePath (1,1) string = ""
            end
            entry = struct("id", char(moduleId));
            if modulePath ~= ""
                entry.path = char(modulePath);
            end
            module = nansen.Module.resolve(entry, obj.Folder);
            entries = nansen.internal.asCellOfStructs(nansen.internal.getField(obj.Document, "modules", []));
            entries = entries(~cellfun(@(e) string(e.id) == moduleId, entries));
            entries{end + 1} = entry;
            document = obj.Document;
            document.modules = entries;
            obj.writeDocument(document)
            obj.ModuleCache = [];
            obj.AdapterCache = [];
        end

        function found = entityMethods(obj, entityType)
            %entityMethods The project's own methods (methods/), then its modules'; the first declaration of an id wins
            arguments
                obj
                entityType (1,1) string = ""
            end
            found = nansen.Method.empty(1, 0);
            folder = fullfile(obj.Folder, "methods");
            if isfolder(folder)
                listing = dir(fullfile(folder, "*.method.nansen.json"));
                for name = sort(string({listing.name}))
                    found(end + 1) = nansen.Method(nansen.readDocument(fullfile(folder, name), ...
                        ExpectedType="nansen.method"), string(fullfile(obj.Folder, "matlab")), "project"); %#ok<AGROW>
                end
            end
            for module = obj.modules()
                found = [found, module.entityMethods()]; %#ok<AGROW>
            end
            if ~isempty(found)
                [~, first] = unique([found.Id], "stable");
                found = found(sort(first));
            end
            if entityType ~= ""
                found = found(arrayfun(@(m) m.appliesTo(entityType), found));
            end
        end

        function method = method(obj, methodId)
            for candidate = obj.entityMethods()
                if candidate.Id == string(methodId)
                    method = candidate;
                    return
                end
            end
            nansen.internal.throwError("unknown-method", "no method '%s'", methodId)
        end

        function found = pipelines(obj, entityType)
            %pipelines Pipelines from pipelines/, then the modules'; the first of an id wins (a cell row of structs)
            arguments
                obj
                entityType (1,1) string = ""
            end
            found = {};
            ids = strings(1, 0);
            folder = fullfile(obj.Folder, "pipelines");
            documents = {};
            if isfolder(folder)
                listing = dir(fullfile(folder, "*.pipeline.nansen.json"));
                for name = sort(string({listing.name}))
                    documents{end + 1} = nansen.readDocument(fullfile(folder, name), ExpectedType="nansen.pipeline"); %#ok<AGROW>
                end
            end
            for module = obj.modules()
                documents = [documents, module.pipelineDocuments()]; %#ok<AGROW>
            end
            for i = 1:numel(documents)
                document = documents{i};
                if ismember(string(document.id), ids)
                    continue
                end
                if entityType == "" || ismember(string(document.entityType), ["*", entityType])
                    found{end + 1} = document; %#ok<AGROW>
                end
                ids(end + 1) = string(document.id); %#ok<AGROW>
            end
        end

        function document = pipeline(obj, pipelineId)
            for candidate = obj.pipelines()
                if string(candidate{1}.id) == string(pipelineId)
                    document = candidate{1};
                    return
                end
            end
            nansen.internal.throwError("unknown-pipeline", "no pipeline '%s'", pipelineId)
        end

        function path = pipelinePath(obj, pipelineId)
            path = string(fullfile(obj.Folder, "pipelines", pipelineId + ".pipeline.nansen.json"));
        end

        function source = pipelineSource(obj, pipelineId)
            %pipelineSource "project" when the project's pipelines/ folder holds it (over a module's of the same id), else "module"
            source = "module";
            if isfile(obj.pipelinePath(string(pipelineId)))
                source = "project";
            end
        end

        function document = savePipeline(obj, document)
            %savePipeline Write a pipeline into the project; one with a module pipeline's id is used instead of that one
            document = nansen.checkDocument(document, ExpectedType="nansen.pipeline");
            entityType = string(document.entityType);
            for step = nansen.internal.asCellOfStructs(document.steps)
                method = obj.method(string(step{1}.method));
                if entityType ~= "*" && ~method.appliesTo(entityType)
                    nansen.internal.throwError("wrong-entity-type", "%s runs on %s, not %s", method.Id, method.EntityType, entityType)
                end
                if isfield(step{1}, "preset")
                    obj.preset(method.Id, string(step{1}.preset));
                end
            end
            path = obj.pipelinePath(string(document.id));
            if ~isfolder(fileparts(path))
                mkdir(fileparts(path));
            end
            nansen.internal.writeJson(path, document)
        end

        function deletePipeline(obj, pipelineId)
            %deletePipeline Delete one of the project's pipelines (a module's of the same id is then used again)
            path = obj.pipelinePath(string(pipelineId));
            if ~isfile(path)
                nansen.internal.throwError("unknown-pipeline", "'%s' is not one of the project's own pipelines", pipelineId)
            end
            delete(path);
        end

        function count = assignPipeline(obj, entityType, keys, pipelineId)
            %assignPipeline Set the pipeline of the given rows (a cell of keys; [] for all rows); "" or [] takes it away
            entityType = string(entityType);
            value = [];
            if ~isempty(pipelineId) && string(pipelineId) ~= ""
                pipeline = obj.pipeline(string(pipelineId));
                if ~ismember(string(pipeline.entityType), ["*", entityType])
                    nansen.internal.throwError("wrong-entity-type", "pipeline '%s' is for %s", pipelineId, pipeline.entityType)
                end
                value = char(pipelineId);
            end
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(obj.entityType(entityType), "fragments", {})));
            if ~ismember("core.pipeline", listed)
                obj.attachFragment(entityType, "core.pipeline");
            end
            table = obj.table(entityType);
            if ~iscell(keys)
                table.fillColumn("pipeline", value);
                count = table.numRows();
            else
                for i = 1:numel(keys)
                    if ~table.hasRow(keys{i})
                        nansen.internal.throwError("unknown-entity", "no row with this key")
                    end
                end
                for i = 1:numel(keys)
                    table.updateRow(keys{i}, struct("pipeline", {value}));
                end
                count = numel(keys);
            end
            table.write();
        end

        function progress = pipelineProgress(obj, entityType)
            %pipelineProgress For each row with a pipeline (runKeyId -> struct pipeline, title, steps, done, total)
            progress = containers.Map("KeyType", "char", "ValueType", "any");
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(obj.entityType(entityType), "fragments", {})));
            if ~ismember("core.pipeline", listed)
                return
            end
            table = obj.table(entityType);
            completed = nansen.internal.completedRuns(obj.Folder, entityType);
            known = containers.Map("KeyType", "char", "ValueType", "any");
            for candidate = obj.pipelines(entityType)
                known(char(string(candidate{1}.id))) = candidate{1};
            end
            assigned = string(table.Data.pipeline);
            for r = 1:table.numRows()
                if ismissing(assigned(r)) || ~isKey(known, char(assigned(r)))
                    continue
                end
                pipeline = known(char(assigned(r)));
                key = struct();
                for name = table.Key
                    value = table.Data.(name)(r);
                    if isstring(value)
                        value = char(value);
                    end
                    key.(name) = value;
                end
                id = nansen.internal.runKeyId(key);
                done = containers.Map("KeyType", "char", "ValueType", "any");
                if isKey(completed, id)
                    done = completed(id);
                end
                stepList = nansen.internal.asCellOfStructs(pipeline.steps);
                steps = cell(1, numel(stepList));
                count = 0;
                for s = 1:numel(stepList)
                    methodId = char(string(stepList{s}.method));
                    title = nansen.internal.getField(stepList{s}, "title", '');
                    if isempty(title)
                        title = char(obj.method(string(methodId)).Title);
                    end
                    finished = [];
                    if isKey(done, methodId)
                        finished = done(methodId);
                        count = count + 1;
                    end
                    steps{s} = struct("title", char(title), "method", methodId, "done", isKey(done, methodId), "finishedAt", finished);
                end
                progress(id) = struct("pipeline", char(string(pipeline.id)), ...
                    "title", char(nansen.internal.getField(pipeline, "title", pipeline.id)), "steps", {steps}, ...
                    "done", count, "total", numel(stepList));
            end
        end

        function path = presetPath(obj, methodId, name)
            path = string(fullfile(obj.Folder, "options", methodId, name + ".options.nansen.json"));
        end

        function presets = presets(obj, methodId)
            %presets Saved option sets of a method after the implicit default: a cell row of structs (name, description, values)
            method = obj.method(methodId);
            presets = {struct("name", 'default', "description", 'The method''s defaults', "values", method.defaultOptions())};
            folder = fullfile(obj.Folder, "options", methodId);
            if isfolder(folder)
                listing = dir(fullfile(folder, "*.options.nansen.json"));
                for name = sort(string({listing.name}))
                    doc = nansen.readDocument(fullfile(folder, name), ExpectedType="nansen.options");
                    presets{end + 1} = struct("name", doc.name, ...
                        "description", char(nansen.internal.getField(doc, "description", "")), "values", doc.values); %#ok<AGROW>
                end
            end
        end

        function values = preset(obj, methodId, name)
            for candidate = obj.presets(methodId)
                if string(candidate{1}.name) == string(name)
                    values = candidate{1}.values;
                    return
                end
            end
            nansen.internal.throwError("unknown-preset", "method '%s' has no preset '%s'", methodId, name)
        end

        function savePreset(obj, methodId, name, values, description)
            arguments
                obj
                methodId (1,1) string
                name (1,1) string
                values (1,1) struct
                description (1,1) string = ""
            end
            if name == "default"
                nansen.internal.throwError("invalid-options", "the 'default' preset is the method's defaults and cannot be saved")
            end
            method = obj.method(methodId);
            resolved = method.resolveOptions(values);
            entry = nansen.internal.schemaEntry("nansen.options");
            document = struct("schemaType", 'nansen.options', "schemaVersion", char(entry.version), ...
                "method", struct("id", char(method.Id), "version", char(method.Version)), "name", char(name), ...
                "values", resolved);
            if description ~= ""
                document.description = char(description);
            end
            document = nansen.checkDocument(document, ExpectedType="nansen.options");
            path = obj.presetPath(methodId, name);
            if ~isfolder(fileparts(path))
                mkdir(fileparts(path));
            end
            nansen.internal.writeJson(path, document)
        end

        function deletePreset(obj, methodId, name)
            path = obj.presetPath(methodId, name);
            if ~isfile(path)
                nansen.internal.throwError("unknown-preset", "method '%s' has no saved preset '%s'", methodId, name)
            end
            delete(path);
        end

        function results = run(obj, methodId, entities, options)
            %run Run a method now, in this MATLAB session, on a cell array of entities of its type
            arguments
                obj
                methodId (1,1) string
                entities (1,:) cell
                options.Options = struct()
                options.Preset (1,1) string = ""
                options.Context = []
            end
            method = obj.method(methodId);
            values = struct();
            if options.Preset ~= ""
                values = obj.preset(methodId, options.Preset);
            end
            values = nansen.internal.mergeStructs(values, options.Options);
            context = options.Context;
            if isempty(context)
                context = nansen.MethodContext(Project=obj, Method=method);
            elseif isempty(context.Project)
                context.Project = obj;
            end
            results = nansen.runMethod(method, entities, values, context);
            nansen.internal.recordRuns(obj.Folder, method.Id, method.Version, entities);
        end

        function summary = updateFragment(obj, entityType, fragmentId, options)
            %updateFragment Recompute a computed fragment's columns for the table rows (or those with the given keys)
            arguments
                obj
                entityType (1,1) string
                fragmentId (1,1) string
                options.Keys (1,:) cell = {}
                options.Context = []
            end
            fragment = obj.fragment(fragmentId);
            if ~isfield(fragment.Document, "compute")
                nansen.internal.throwError("not-computed", "fragment '%s' has no compute method", fragmentId)
            end
            entry = obj.entityType(entityType);
            if ~ismember(fragmentId, string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {}))))
                nansen.internal.throwError("unknown-fragment", "entity type '%s' does not carry '%s'", entityType, fragmentId)
            end
            method = obj.method(fragment.Document.compute.method);
            table = obj.table(entityType);
            entities = obj.entities(entityType);
            entities = entities(cellfun(@(e) e.inTable(), entities));
            if ~isempty(options.Keys)
                wanted = cellfun(@(k) keyTextOf(k, table.Key), options.Keys, UniformOutput=false);
                entities = entities(cellfun(@(e) ismember(keyTextOf(e.Key, table.Key), wanted), entities));
            end
            context = options.Context;
            if isempty(context)
                context = nansen.MethodContext(Project=obj, Method=method);
            end
            context.Project = obj;
            resolved = method.resolveOptions(struct());
            handle = method.functionHandle();
            names = [fragment.Columns.Name];
            updated = 0;
            failed = {};
            for i = 1:numel(entities)
                context.checkCancelled()
                entity = entities{i};
                try
                    result = handle(entity, resolved, context);
                    values = struct();
                    for name = names
                        if isstruct(result) && isfield(result, name)
                            values.(name) = result.(name);
                        end
                    end
                    table.updateRow(entity.Key, values)
                    updated = updated + 1;
                catch err
                    failed{end + 1} = struct("key", entity.Key, "error", [err.identifier, ': ', err.message]); %#ok<AGROW>
                    context.log("%s: %s", jsonencode(entity.Key), err.message)
                end
                context.progress(i / max(numel(entities), 1))
            end
            table.write()
            summary = struct("updated", updated, "failed", {failed});
        end

        function path = dataVariablePath(obj, name)
            path = string(fullfile(obj.Folder, "data-variables", name + ".dataVariable.nansen.json"));
        end

        function variables = dataVariables(obj, entityType)
            %dataVariables The project's data variables, optionally of one entity type: a row of nansen.DataVariable
            arguments
                obj
                entityType (1,1) string = ""
            end
            variables = nansen.DataVariable.empty(1, 0);
            folder = fullfile(obj.Folder, "data-variables");
            if ~isfolder(folder)
                return
            end
            listing = dir(fullfile(folder, "*.dataVariable.nansen.json"));
            for name = sort(string({listing.name}))
                variable = nansen.DataVariable(nansen.readDocument(fullfile(folder, name), ExpectedType="nansen.dataVariable"));
                if entityType == "" || variable.EntityType == entityType
                    variables(end + 1) = variable; %#ok<AGROW>
                end
            end
        end

        function variable = dataVariable(obj, name)
            path = obj.dataVariablePath(name);
            if ~isfile(path)
                nansen.internal.throwError("unknown-data-variable", "no data variable '%s'", name)
            end
            variable = nansen.DataVariable(nansen.readDocument(path, ExpectedType="nansen.dataVariable"));
        end

        function variable = addDataVariable(obj, document)
            %addDataVariable Save a data variable; its entity type, location, file pattern and adapter must exist
            document = nansen.checkDocument(document, ExpectedType="nansen.dataVariable");
            variable = nansen.DataVariable(document);
            obj.entityType(variable.EntityType);
            if ~obj.adapters().has(variable.FileAdapter)
                nansen.internal.throwError("unknown-file-adapter", "no file adapter '%s'", variable.FileAdapter)
            end
            dataset = obj.requireDataset();
            if ~ismember(variable.DataLocation, dataset.Config.locationIds())
                nansen.internal.throwError("unknown-location", "the dataset has no data location '%s'", variable.DataLocation)
            end
            patterns = obj.levelPatterns(variable);
            if variable.FilePattern ~= "" && ~isKey(patterns, char(variable.FilePattern))
                nansen.internal.throwError("unknown-file-pattern", "no file pattern '%s' at that level", variable.FilePattern)
            end
            folder = fullfile(obj.Folder, "data-variables");
            if ~isfolder(folder)
                mkdir(folder);
            end
            nansen.internal.writeJson(obj.dataVariablePath(variable.Name), document)
        end

        function patterns = levelPatterns(obj, variable)
            %levelPatterns File pattern names to patterns at the variable's entity level in its location
            patterns = containers.Map("KeyType", "char", "ValueType", "char");
            config = obj.requireDataset().Config;
            if ~ismember(variable.DataLocation, config.locationIds())
                return
            end
            index = config.entityLevelIndex(variable.DataLocation, variable.EntityType);
            if isempty(index)
                return
            end
            levels = config.layout(variable.DataLocation);
            for item = nansen.internal.asCellOfStructs(nansen.internal.getField(levels{index}, "filePatterns", []))
                if isfield(item{1}, "name")
                    patterns(char(item{1}.name)) = char(item{1}.pattern);
                end
            end
        end

        function targets = readTargets(obj, entity, name)
            %readTargets [dataLocation, relative path] of each file that holds the variable for the entity (N-by-2 string)
            variable = obj.dataVariable(name);
            targets = strings(0, 2);
            if variable.FilePattern ~= ""
                if ~isKey(obj.levelPatterns(variable), char(variable.FilePattern))
                    nansen.internal.throwError("unknown-file-pattern", "no file pattern '%s' at the %s level of '%s'", ...
                        variable.FilePattern, variable.EntityType, variable.DataLocation)
                end
                for path = entity.files(variable.DataLocation, variable.FilePattern)
                    targets(end + 1, :) = [variable.DataLocation, path]; %#ok<AGROW>
                end
                return
            end
            location = entity.location(variable.DataLocation);
            if isempty(location) || string(nansen.internal.getField(location, "fileSystemType", "folder")) ~= "folder"
                return
            end
            relative = variable.relativeFile(entity.values());
            for folder = reshape(string(nansen.internal.asCellstr(location.paths)), 1, [])
                targets(end + 1, :) = [variable.DataLocation, folder + relative]; %#ok<AGROW>
            end
        end

        function [dataLocation, relative] = writeTarget(obj, entity, name)
            %writeTarget Where the variable is written: in the entity's folder, generated by DSM if it has none yet
            variable = obj.dataVariable(name);
            dataset = obj.requireDataset();
            values = entity.values();
            location = entity.location(variable.DataLocation);
            if ~isempty(location) && string(nansen.internal.getField(location, "fileSystemType", "folder")) == "folder" ...
                    && ~isempty(location.paths)
                paths = sort(string(nansen.internal.asCellstr(location.paths)));
                folder = paths(1);
            else
                folder = dataset.generatePath(variable.DataLocation, entity.EntityType, values);
            end
            if variable.FilePattern ~= ""
                patterns = obj.levelPatterns(variable);
                regex = nansen.internal.patternRegex(patterns(char(variable.FilePattern)), values);
                file = variable.relativeFile(values);
                parts = split(file, "/");
                if isempty(regexp(char(parts(end)), regex, "once"))
                    nansen.internal.throwError("file-name-mismatch", "data variable '%s': '%s' does not match file pattern '%s'", ...
                        variable.Name, parts(end), patterns(char(variable.FilePattern)))
                end
            end
            dataLocation = variable.DataLocation;
            relative = folder + variable.relativeFile(values);
        end

        function paths = dataPaths(obj, entity, name)
            %dataPaths Absolute paths of the files that hold the variable for the entity (they may not exist)
            dataset = obj.requireDataset();
            targets = obj.readTargets(entity, name);
            paths = strings(1, size(targets, 1));
            for i = 1:size(targets, 1)
                paths(i) = dataset.absolute(targets(i, 1), targets(i, 2));
            end
        end

        function path = writePath(obj, entity, name)
            [dataLocation, relative] = obj.writeTarget(entity, name);
            path = obj.requireDataset().absolute(dataLocation, relative);
        end

        function data = load(obj, entity, name, options)
            %load Read the variable for the entity with its file adapter (the first file when several match)
            %
            %   What was read is kept in obj.DataCache and given again until the
            %   file changes; load(..., Cached=false) reads the file and keeps nothing.
            arguments
                obj
                entity
                name (1,1) string
                options.Cached (1,1) logical = true
            end
            variable = obj.dataVariable(name);
            paths = obj.dataPaths(entity, name);
            paths = paths(arrayfun(@isfile, paths));
            if isempty(paths)
                nansen.internal.throwError("data-not-found", "%s has no '%s'", entity.EntityType, name)
            end
            adapter = obj.adapters().get(variable.FileAdapter);
            path = paths(1);
            if ~options.Cached
                data = adapter.read(path);
                return
            end
            info = dir(path);
            data = obj.DataCache.getOrLoad(nansen.Project.cacheKey(variable.FileAdapter, path), ...
                [info.datenum, info.bytes], @() adapter.read(path));
        end

        function path = save(obj, entity, name, data)
            %save Write the variable for the entity, creating folders as needed; returns the path written
            variable = obj.dataVariable(name);
            path = obj.writePath(entity, name);
            folder = fileparts(path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            obj.adapters().get(variable.FileAdapter).write(path, data);
            obj.DataCache.remove(nansen.Project.cacheKey(variable.FileAdapter, path));   % a rewrite in the same tick keeps the time
        end

        function status = dataStatus(obj, entity)
            %dataStatus Each data variable of the entity's type: whether a file exists, and where
            status = {};
            for variable = obj.dataVariables(entity.EntityType)
                try
                    paths = obj.dataPaths(entity, variable.Name);
                catch err
                    if ~isa(err, "nansen.NansenError")
                        rethrow(err)
                    end
                    paths = strings(1, 0);
                end
                files = paths(arrayfun(@isfile, paths));
                status{end + 1} = struct("name", char(variable.Name), "dataLocation", char(variable.DataLocation), ...
                    "fileAdapter", char(variable.FileAdapter), "files", {cellstr(files)}); %#ok<AGROW>
            end
        end

        function table = detachFragment(obj, entityType, fragmentId)
            %detachFragment Take a fragment off an entity type: its columns, and their values, leave the table
            arguments
                obj
                entityType (1,1) string
                fragmentId (1,1) string
            end
            entry = obj.entityType(entityType);
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {})));
            if ~ismember(fragmentId, listed)
                nansen.internal.throwError("unknown-fragment", "%s has no fragment '%s'", entityType, fragmentId)
            end
            table = obj.table(entityType);
            table.removeColumns([table.Columns([table.Columns.Fragment] == fragmentId).Name], fragmentId);
            table.write();
            entry.fragments = cellstr(listed(listed ~= fragmentId));
            document = obj.Document;
            document.entityTypes{obj.EntityTypes == entityType} = entry;
            obj.writeDocument(document);
        end

        function count = resetColumn(obj, entityType, column, keys)
            %resetColumn Give a column its default again (none when it has none), in the given rows (a cell of keys) or all
            table = obj.table(entityType);
            column = string(column);
            if ~ismember(column, table.columnNames())
                nansen.internal.throwError("unknown-column", "%s has no column '%s'", entityType, column)
            end
            if ismember(column, table.Key)
                nansen.internal.throwError("read-only-column", "cannot reset key column '%s'", column)
            end
            default = nansen.internal.getField(table.Defaults, column, []);
            if nargin < 4
                table.fillColumn(column, default);
                count = table.numRows();
            else
                for i = 1:numel(keys)
                    if ~table.hasRow(keys{i})
                        nansen.internal.throwError("unknown-entity", "no row with this key")
                    end
                end
                for i = 1:numel(keys)
                    table.updateRow(keys{i}, struct(column, {default}));
                end
                count = numel(keys);
            end
            table.write();
        end

        function choices = columnChoices(obj, entityType)
            %columnChoices The choices of the entity type's columns that have them (a struct: column -> string row)
            choices = struct();
            entry = obj.entityType(entityType);
            for fragmentId = string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {})))
                for column = nansen.internal.asCellOfStructs(obj.fragment(fragmentId).Document.columns)
                    if isfield(column{1}, "choices")
                        choices.(column{1}.name) = reshape(string(nansen.internal.asCellstr(column{1}.choices)), 1, []);
                    end
                end
            end
        end

        function checkChoices(obj, entityType, values)
            %checkChoices invalid-value when a value is not among its column's choices (none is always allowed)
            choices = obj.columnChoices(entityType);
            for name = reshape(string(fieldnames(choices)), 1, [])
                if ~isfield(values, name)
                    continue
                end
                value = values.(name);
                if (isnumeric(value) && isempty(value)) || (isstring(value) && isscalar(value) && ismissing(value))
                    continue   % none; "" is a value, and has to be a choice
                end
                if ~(ischar(value) || isstring(value)) || ~ismember(string(value), choices.(name))
                    nansen.internal.throwError("invalid-value", "'%s' is one of %s, not '%s'", name, ...
                        strjoin(choices.(name), ", "), string(value))
                end
            end
        end

        function table = attachFragment(obj, entityType, fragmentId)
            %attachFragment Add a fragment to an entity type that may already have rows; they get the columns' defaults
            arguments
                obj
                entityType (1,1) string
                fragmentId (1,1) string
            end
            entry = obj.entityType(entityType);
            fragment = obj.fragment(fragmentId);
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(entry, "fragments", {})));
            if ismember(fragmentId, listed)
                nansen.internal.throwError("fragment-exists", "%s already has fragment '%s'", entityType, fragmentId)
            end
            table = obj.table(entityType);
            clash = sort(intersect(table.columnNames(), [fragment.Columns.Name]));
            if ~isempty(clash)
                nansen.internal.throwError("column-exists", "%s already has column(s) %s", entityType, strjoin(clash, ", "))
            end
            table.addColumns(fragment.Columns, fragment.Defaults, fragment.Id, fragment.Version);
            table.write();
            entry.fragments = cellstr([listed, fragmentId]);
            document = obj.Document;
            document.entityTypes{obj.EntityTypes == entityType} = entry;
            obj.writeDocument(document);
        end

        function fragment = addFragment(obj, document)
            %addFragment Save a project-defined fragment, given as a struct
            arguments
                obj
                document (1,1) struct
            end
            document = nansen.checkDocument(document, ExpectedType="nansen.fragment");
            fragment = nansen.Fragment(document);
            nansen.internal.writeJson(obj.fragmentPath(fragment.Id), document)
        end
    end

    methods (Access = private)
        function writeDocument(obj, document)
            document = nansen.checkDocument(document, ExpectedType="nansen.project");
            nansen.internal.writeJson(fullfile(obj.Folder, nansen.Project.ProjectFile), document)
            document.entityTypes = nansen.internal.asCellOfStructs(document.entityTypes);
            obj.Document = document;
        end
    end

    methods (Static, Access = private)
        function key = cacheKey(adapterId, path)
            % One entry per file and file adapter
            key = string(adapterId) + "|" + string(path);
        end
    end

    methods (Static)
        function name = defaultEnvironment()
            %defaultEnvironment This machine's environment name when none is set: its host name, as a DSM identifier
            name = string(getenv("COMPUTERNAME"));
            if name == ""
                [status, output] = system("hostname");
                if status == 0
                    name = strtrim(string(output));
                end
            end
            name = regexprep(lower(name), "[^a-z0-9-]+", "-");
            name = regexprep(name, "^-+|-+$", "");
            if name == "" || isempty(regexp(name, "^[a-z]", "once"))
                if name == ""
                    name = "local";
                end
                name = "machine-" + name;
            end
        end

        function obj = create(folder, name, options)
            %create Make a project folder with an empty project file, fragments/ and tables/
            %
            %   Dataset is the path of a DSM config, relative to the folder.
            arguments
                folder (1,1) string
                name (1,1) string
                options.Title (1,1) string = ""
                options.Dataset (1,1) string = ""
                options.Description (1,1) string = ""
            end
            if isfile(fullfile(folder, nansen.Project.ProjectFile))
                nansen.internal.throwError("folder-not-empty", "%s already holds a project", folder)
            end
            entry = nansen.internal.schemaEntry("nansen.project");
            document = struct("schemaType", 'nansen.project', "schemaVersion", char(entry.version), "name", char(name));
            if options.Title ~= ""
                document.title = char(options.Title);
            end
            if options.Description ~= ""
                document.description = char(options.Description);
            end
            if options.Dataset ~= ""
                document.dataset = char(options.Dataset);
            end
            document.entityTypes = {};
            document = nansen.checkDocument(document, ExpectedType="nansen.project");
            for sub = ["", "fragments", "tables"]
                target = fullfile(folder, sub);
                if ~isfolder(target)
                    mkdir(target);
                end
            end
            obj = nansen.Project(folder, document);
            obj.writeDocument(obj.Document)
        end

        function obj = open(folder, options)
            arguments
                folder (1,1) string
                options.Environment (1,1) string = ""
            end
            document = nansen.readDocument(fullfile(folder, nansen.Project.ProjectFile), ExpectedType="nansen.project");
            obj = nansen.Project(folder, document, options.Environment);
        end

        function key = recordKeyOf(record)
            %recordKeyOf The key of a DSM record without a dataset: parents' identity, then its own
            key = struct();
            for parent = nansen.internal.asCellOfStructs(record.parents)
                for name = reshape(string(fieldnames(parent{1}.identity)), 1, [])
                    key.(name) = parent{1}.identity.(name);
                end
            end
            for name = reshape(string(fieldnames(record.identity)), 1, [])
                key.(name) = record.identity.(name);
            end
        end

        function checkFragments(table, fragments)
            %checkFragments A table must hold exactly the declared fragments, at their versions, with their columns
            declared = string(cellfun(@(f) f.Id, fragments, UniformOutput=false));
            for id = table.FragmentIds
                if ~ismember(id, declared)
                    nansen.internal.throwError("fragment-mismatch", ...
                        "table holds fragment '%s', which the entity type does not list", id)
                end
            end
            for i = 1:numel(fragments)
                fragment = fragments{i};
                position = find(table.FragmentIds == fragment.Id, 1);
                if isempty(position) || table.FragmentVersions(position) ~= fragment.Version
                    recorded = "(absent)";
                    if ~isempty(position)
                        recorded = table.FragmentVersions(position);
                    end
                    nansen.internal.throwError("fragment-mismatch", ...
                        "table follows %s %s, the definition is %s", fragment.Id, recorded, fragment.Version)
                end
                owned = table.Columns([table.Columns.Fragment] == fragment.Id);
                if ~isequal([owned.Name], [fragment.Columns.Name]) || ~isequal([owned.DataType], [fragment.Columns.DataType])
                    nansen.internal.throwError("fragment-mismatch", ...
                        "table columns for %s differ from the definition", fragment.Id)
                end
            end
        end
    end
end

function text = keyTextOf(key, keyColumns)
    parts = cell(1, numel(keyColumns));
    for i = 1:numel(keyColumns)
        parts{i} = key.(keyColumns(i));
    end
    text = nansen.internal.keyText(parts);
end

function roots = rootsOf(location)
    filesystem = nansen.internal.getField(location, "filesystemSource", struct());
    roots = nansen.internal.asCellOfStructs(nansen.internal.getField(filesystem, "rootStoragePaths", []));
end

function id = rootIdentifier(environment, roots)
    % A root identifier for the environment, unique among the location's roots (as Python's _root_identifier)
    base = regexprep(char(environment), '[^A-Za-z0-9_-]+', '-');
    base = regexprep(base, '^-+|-+$', '');
    if isempty(base)
        base = 'root';
    end
    if ~isletter(base(1))
        base = ['root-', base];
    end
    used = string(cellfun(@(r) string(nansen.internal.getField(r, "identifier", "")), roots, UniformOutput=false));
    id = string(base);
    n = 2;
    while ismember(id, used)
        id = string(base) + "-" + n;
        n = n + 1;
    end
end

function setEnvironment(configPath, environment)
    % Make the environment active on this machine, in the DSM config's .local.json overlay
    [folder, stem] = fileparts(configPath);
    overlay = fullfile(folder, stem + ".local.json");
    if isfile(overlay)
        text = nansen.internal.readText(overlay);
        if isfield(jsondecode(char(text)), "preferences")
            text = nansen.internal.JsonText.setMember(text, "/preferences", "environmentIdentifier", environment);
        else
            text = nansen.internal.JsonText.setMember(text, "", "preferences", struct("environmentIdentifier", char(environment)));
        end
    else
        text = "{" + newline + "  ""preferences"": {" + newline + "    ""environmentIdentifier"": " + ...
            nansen.internal.JsonText.encode(environment) + newline + "  }" + newline + "}" + newline;
    end
    nansen.internal.writeText(overlay, text);
end
