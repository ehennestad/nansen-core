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

    properties
        % The most frames a stack from openStack gives in one read (Inf: no limit); a test sets it to show
        % that a method reads a recording in chunks
        StackFrameLimit (1,1) double = Inf
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

        function updateInfo(obj, options)
            %updateInfo Change the project's title or description, or entity types' titles; an empty text removes it
            arguments
                obj
                options.Title (1,1) string = missing
                options.Description (1,1) string = missing
                options.EntityTypeTitles (1,1) struct = struct()   % entity type name -> title
            end
            names = string(fieldnames(options.EntityTypeTitles))';
            for name = names
                obj.entityType(name);   % unknown-entity-type before anything changes
            end
            document = obj.Document;
            fields = ["title", "description"];
            values = [options.Title, options.Description];
            for i = 1:2
                if ismissing(values(i))
                    continue
                end
                if strtrim(values(i)) ~= ""
                    document.(fields(i)) = char(strtrim(values(i)));
                elseif isfield(document, fields(i))
                    document = rmfield(document, fields(i));
                end
            end
            for i = 1:numel(document.entityTypes)
                name = string(document.entityTypes{i}.name);
                if ismember(name, names)
                    value = strtrim(string(options.EntityTypeTitles.(name)));
                    if value ~= ""
                        document.entityTypes{i}.title = char(value);
                    elseif isfield(document.entityTypes{i}, "title")
                        document.entityTypes{i} = rmfield(document.entityTypes{i}, "title");
                    end
                end
            end
            obj.writeDocument(document)
        end

        function name = preferredPreset(obj, methodId)
            %preferredPreset The preset the method runs with when a run gives neither a preset nor options ("" for none), if it is still there
            name = "";
            for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(obj.Document, "preferredPresets", {}))
                if string(entry{1}.method) == string(methodId)
                    name = string(entry{1}.preset);
                end
            end
            if name ~= "" && ~any(cellfun(@(p) string(p.name) == name, obj.presets(methodId)))
                name = "";
            end
        end

        function setPreferredPreset(obj, methodId, name)
            %setPreferredPreset Make a preset the method's own default (dev's preferred options); "" or "default" goes back to the defaults
            obj.method(methodId);   % unknown-method
            kept = {};
            for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(obj.Document, "preferredPresets", {}))
                if string(entry{1}.method) ~= string(methodId)
                    kept{end + 1} = struct("method", char(entry{1}.method), "preset", char(entry{1}.preset)); %#ok<AGROW>
                end
            end
            if ~ismember(string(name), ["", "default"])
                obj.preset(methodId, name);   % unknown-preset
                kept{end + 1} = struct("method", char(methodId), "preset", char(name));
            end
            document = obj.Document;
            if isempty(kept)
                if isfield(document, "preferredPresets")
                    document = rmfield(document, "preferredPresets");
                end
            else
                document.preferredPresets = kept;
            end
            obj.writeDocument(document)
        end

        function result = excludeFromScan(obj, dataLocation, path)
            %excludeFromScan Have scans skip an entry the last scan did not match
            %
            %   Adds an excludePatterns entry for its exact name, at its level in
            %   the data location, to the DSM config's text. The last scan forgets
            %   it too.
            dataLocation = string(dataLocation);
            dataset = obj.requireDataset();
            parts = split(replace(string(path), "\", "/"), "/")';
            parts = parts(parts ~= "");
            if isempty(parts) || any(ismember(parts, [".", ".."]))
                nansen.internal.throwError("invalid-params", "'%s' is not a path in the data location", path)
            end
            if ~ismember(dataLocation, dataset.Config.locationIds())
                nansen.internal.throwError("unknown-location", "the dataset has no data location '%s'", dataLocation)
            end
            levels = dataset.Config.layout(dataLocation);
            if numel(parts) > numel(levels)
                nansen.internal.throwError("invalid-params", "'%s' is deeper than the levels of '%s'", path, dataLocation)
            end
            level = numel(parts);
            name = char(parts(end));
            escaped = '';
            for c = name
                if any(c == '\.^$|?*+()[]{}')
                    escaped = [escaped, '\', c]; %#ok<AGROW>
                else
                    escaped = [escaped, c]; %#ok<AGROW>
                end
            end
            pattern = "^" + string(escaped) + "$";
            text = obj.datasetText();
            config = jsondecode(char(text));
            locations = nansen.internal.asCellOfStructs(config.dataLocations);
            index = find(cellfun(@(l) string(l.identifier) == dataLocation, locations), 1);
            layout = nansen.internal.asCellOfStructs(locations{index}.filesystemSource.entityLayout);
            pointer = sprintf("/dataLocations/%d/filesystemSource/entityLayout/%d", index - 1, level - 1);
            changed = text;
            if ~isfield(layout{level}, "excludePatterns")
                changed = nansen.internal.JsonText.setMember(text, pointer, "excludePatterns", {char(pattern)});
            elseif ~ismember(pattern, string(nansen.internal.asCellstr(layout{level}.excludePatterns)))
                changed = nansen.internal.JsonText.append(text, pointer + "/excludePatterns", char(pattern));
            end
            if changed ~= text
                obj.saveDatasetText(changed);
            end
            scan = obj.lastScan();
            if ~isempty(scan)
                prefix = strjoin(parts, "/") + "/";
                keep = true(1, numel(scan.Unmatched));
                for i = 1:numel(scan.Unmatched)
                    entry = scan.Unmatched{i};
                    entryPath = replace(string(nansen.internal.getField(entry, "path", "")) + "/", "//", "/");
                    keep(i) = ~(string(nansen.internal.getField(entry, "dataLocationIdentifier", "")) == dataLocation ...
                        && startsWith(entryPath, prefix));
                end
                scan.Unmatched = scan.Unmatched(keep);
                scan.write(obj.scanPath());
            end
            levelName = string(levels{level}.name);
            result = struct("dataLocation", char(dataLocation), "level", char(levelName), "pattern", char(pattern));
        end

        % -- entries matched to entities by hand ----------------------------------------------

        function path = assignmentsPath(obj)
            path = string(fullfile(obj.Folder, "dataset.assignments.nansen.json"));
        end

        function assignments = assignments(obj)
            %assignments The entries of the data locations matched to an entity by hand, in the order
            %   they were first made: a cell row of structs {dataLocation, path, entityType, key}
            assignments = {};
            if isfile(obj.assignmentsPath())
                document = nansen.readDocument(obj.assignmentsPath(), ExpectedType="nansen.assignments");
                assignments = nansen.internal.asCellOfStructs(document.assignments);
            end
        end

        function assignment = assignEntry(obj, dataLocation, path, key)
            %assignEntry Match an entry of a data location to the entity with this key, whatever its name
            %
            %   From the next scan on (dev's FolderMatcherDialog). It must be at a
            %   level that holds an entity type; one assigned before is assigned
            %   anew, in its place.
            dataset = obj.requireDataset();
            dataLocation = string(dataLocation);
            [path, ~, entityType] = dataset.assignmentTarget(dataLocation, path);
            assignment = struct("dataLocation", char(dataLocation), "path", char(path), ...
                "entityType", char(entityType), "key", dataset.checkKey(entityType, key));
            assignments = obj.assignments();
            index = [];
            for i = 1:numel(assignments)
                if string(assignments{i}.dataLocation) == dataLocation && string(assignments{i}.path) == path
                    index = i;
                    break
                end
            end
            if isempty(index)
                assignments{end + 1} = assignment;
            else
                assignments{index} = assignment;
            end
            obj.writeAssignments(assignments);
        end

        function removed = unassignEntry(obj, dataLocation, path)
            %unassignEntry Undo an assignment (unknown-assignment if there is none)
            names = nansen.Dataset.entryParts(path);
            assignments = obj.assignments();
            index = [];
            for i = 1:numel(assignments)
                if string(assignments{i}.dataLocation) == string(dataLocation) ...
                        && isequal(nansen.Dataset.entryParts(assignments{i}.path), names)
                    index = i;
                    break
                end
            end
            if isempty(index)
                nansen.internal.throwError("unknown-assignment", "'%s' of '%s' is not assigned to an entity", ...
                    string(path), string(dataLocation))
            end
            removed = assignments{index};
            assignments(index) = [];
            obj.writeAssignments(assignments);
        end

        function document = parseDatasetText(~, text)
            %parseDatasetText A DSM config from its text, as DSM accepts it (dataset-invalid otherwise)
            try
                document = jsondecode(char(text));
            catch err
                nansen.internal.throwError("dataset-invalid", "not valid JSON: %s", err.message)
            end
            if ~isstruct(document) || ~isscalar(document)
                nansen.internal.throwError("dataset-invalid", "a DSM config is a JSON object")
            end
            try
                dsm.validateConfig(document);
            catch err
                if isa(err, "dsm.ConfigError")
                    nansen.internal.throwError("dataset-invalid", "%s", err.message)
                end
                rethrow(err)
            end
        end

        function dataset = setDatasetText(obj, text)
            %setDatasetText Give a project without a dataset this DSM config, written as dataset.dsm.json as given
            if isfield(obj.Document, "dataset")
                nansen.internal.throwError("dataset-exists", "project '%s' already has a dataset", obj.Name)
            end
            obj.parseDatasetText(text);
            target = fullfile(obj.Folder, "dataset.dsm.json");
            nansen.internal.writeText(target, string(text));
            document = obj.Document;
            document.dataset = 'dataset.dsm.json';
            previous = obj.Document;
            obj.Document = document;
            obj.DatasetCache = [];
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

        function result = testDatasetText(obj, text, examples)
            %testDatasetText What a scan with this DSM config would find, without keeping it
            %
            %   Counts and examples per entity type, and what it would not match.
            %   Relative roots are read from the project folder.
            arguments
                obj
                text
                examples (1,1) double = 5
            end
            document = obj.parseDatasetText(text);
            config = dsm.Config(document, string(fullfile(obj.Folder, "dataset.dsm.json")));
            dataset = nansen.Dataset(config, obj.Folder, obj.Environment);
            scan = dataset.scan([]);
            records = struct();
            found = struct();
            for i = 1:numel(scan.Records)
                record = scan.Records{i};
                type = string(record.entityType);
                records.(type) = nansen.internal.getField(records, type, 0) + 1;
                shown = nansen.internal.getField(found, type, {});
                if numel(shown) < examples
                    shown{end + 1} = dataset.recordKey(record); %#ok<AGROW>
                end
                found.(type) = shown;
            end
            unmatched = nansen.Api.unmatchedOf(scan);
            keys = strings(1, numel(unmatched));
            for i = 1:numel(unmatched)
                keys(i) = string(nansen.internal.getField(unmatched{i}, "dataLocationIdentifier", "")) + char(0) + ...
                    string(nansen.internal.getField(unmatched{i}, "path", ""));
            end
            [~, order] = sort(keys);
            unmatched = unmatched(order);
            shown = cell(1, min(10, numel(unmatched)));
            for i = 1:numel(shown)
                u = unmatched{i};
                shown{i} = struct("dataLocation", char(nansen.internal.getField(u, "dataLocationIdentifier", "")), ...
                    "path", char(nansen.internal.getField(u, "path", "")), "reason", char(nansen.internal.getField(u, "reason", "")));
            end
            result = struct("records", records, "examples", found, "roots", {scan.Roots}, ...
                "unmatched", numel(unmatched), "unmatchedExamples", {shown});
        end

        function text = datasetText(obj)
            %datasetText The DSM config as written, so it can be edited with its formatting
            obj.requireDataset();
            text = string(nansen.internal.readText(fullfile(obj.Folder, obj.Document.dataset)));
        end

        function dataset = saveDatasetText(obj, text)
            %saveDatasetText Replace the DSM config with this text once DSM accepts it and the tables' keys still match it
            %
            %   The file is written as given. If the new config cannot be used,
            %   the old text is put back.
            obj.requireDataset();
            name = string(obj.Document.dataset);
            try
                document = jsondecode(char(text));
            catch err
                nansen.internal.throwError("dataset-invalid", "%s: not valid JSON: %s", name, err.message)
            end
            if ~isstruct(document) || ~isscalar(document)
                nansen.internal.throwError("dataset-invalid", "%s: a DSM config is a JSON object", name)
            end
            try
                dsm.validateConfig(document);
            catch err
                if isa(err, "dsm.ConfigError")
                    nansen.internal.throwError("dataset-invalid", "%s: %s", name, err.message)
                end
                rethrow(err)
            end
            configPath = fullfile(obj.Folder, name);
            old = nansen.internal.readText(configPath);
            nansen.internal.writeText(configPath, string(text));
            obj.DatasetCache = [];
            try
                dataset = obj.requireDataset();
                for entry = obj.Document.entityTypes
                    entityType = string(entry{1}.name);
                    if ismember(entityType, dataset.entityTypes()) && isfile(obj.tablePath(entityType))
                        key = obj.table(entityType).Key;
                        keyColumns = dataset.keyColumns(entityType);
                        expected = [keyColumns.Name];
                        if ~isequal(expected, key)
                            nansen.internal.throwError("key-mismatch", ...
                                "the %s table's key %s differs from the identity the new config gives it %s", ...
                                entityType, strjoin(key, ","), strjoin(expected, ","))
                        end
                    end
                end
            catch err
                nansen.internal.writeText(configPath, string(old));
                obj.DatasetCache = [];
                rethrow(err)
            end
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
            registry = options.Registry;
            if isempty(registry)
                registry = dsm.ExtractorRegistry();
            end
            result = dataset.scan(listing, registry, obj.assignments());
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
            rules = {};
            listed = string(nansen.internal.asCellstr(nansen.internal.getField(obj.entityType(entityType), "fragments", {})));
            if ismember("core.pipeline", listed)
                for pipeline = obj.pipelines(entityType)
                    if isfield(pipeline{1}, "assignWhen") && ~isempty(pipeline{1}.assignWhen)
                        rule = pipeline{1};
                        rule.assignWhen = nansen.internal.asCellOfStructs(rule.assignWhen);
                        rules{end + 1} = rule; %#ok<AGROW>
                    end
                end
            end
            added = {};
            rows = {};
            for candidate = obj.entities(entityType, scan)
                entity = candidate{1};
                if entity.inTable() || any(cellfun(@(i) string(i.code) == "incomplete-key", entity.Issues))
                    continue
                end
                added{end + 1} = entity.Key; %#ok<AGROW>
                row = entity.Key;
                if ~isempty(rules)   % the first pipeline whose rule the new row passes, as dev assigns pipelines to new sessions
                    values = nansen.internal.mergeStructs(nansen.internal.mergeStructs(table.Defaults, entity.attributes()), entity.Key);
                    for r = 1:numel(rules)
                        matched = true;
                        for f = rules{r}.assignWhen
                            matched = matched && nansen.Views.passes(nansen.internal.getField(values, f{1}.column, []), f{1});
                        end
                        if matched
                            row.pipeline = char(string(rules{r}.id));
                            break
                        end
                    end
                end
                rows{end + 1} = row; %#ok<AGROW>
            end
            if ~isempty(rows)
                table.addRows(rows);   % at once: one row at a time grows the table quadratically
                table.write()
            end
        end

        % -- data variables and file adapters ------------------------------------------

        function result = createAdapter(obj, adapterId, options)
            %createAdapter Start a file adapter of the project: its document in file-adapters/ and, per language,
            %   a class to fill in (python/<id>_adapter.py, matlab/<Id>Adapter.m), from the templates that ship with NANSEN
            arguments
                obj
                adapterId (1,1) string
                options.Title (1,1) string = ""
                options.Extensions (1,:) string = strings(1, 0)
                options.Languages (1,:) string = ["python", "matlab"]
            end
            if isempty(regexp(adapterId, "^[a-z][a-z0-9_]*$", "once"))
                nansen.internal.throwError("invalid-params", "a project adapter's id is a lower-case letter, then letters, digits or _")
            end
            languages = unique(options.Languages, "stable");
            if isempty(languages) || ~all(ismember(languages, ["python", "matlab"]))
                nansen.internal.throwError("invalid-params", "languages are python and/or matlab")
            end
            extensions = unique(options.Extensions, "stable");
            for extension = extensions
                if isempty(regexp(extension, "^\.[A-Za-z0-9.]+$", "once"))
                    nansen.internal.throwError("invalid-params", "'%s' is not a file extension such as .tif", extension)
                end
            end
            title = strjoin(split(strtrim(options.Title))', " ");
            if title == ""
                title = adapterId;
            end
            parts = split(adapterId, "_")';
            capitalized = arrayfun(@(p) char(upper(extractBefore(p, 2)) + extractAfter(p, 1)), parts, UniformOutput=false);
            className = strjoin(string(capitalized), "") + "Adapter";
            paths = string(fullfile(obj.Folder, "file-adapters", adapterId + ".fileAdapter.nansen.json"));
            relative = "file-adapters/" + adapterId + ".fileAdapter.nansen.json";
            templates = "";
            if ismember("python", languages)
                paths(end + 1) = string(fullfile(obj.Folder, "python", adapterId + "_adapter.py"));
                relative(end + 1) = "python/" + adapterId + "_adapter.py";
                templates(end + 1) = "adapter.py.template";
            end
            if ismember("matlab", languages)
                paths(end + 1) = string(fullfile(obj.Folder, "matlab", className + ".m"));
                relative(end + 1) = "matlab/" + className + ".m";
                templates(end + 1) = "adapter.m.template";
            end
            existing = relative(isfile(paths));
            if ~isempty(existing) || ismember(adapterId, obj.adapters().ids())
                what = "a file adapter '" + adapterId + "'";
                if ~isempty(existing)
                    what = strjoin(existing, ", ");
                end
                nansen.internal.throwError("adapter-exists", "the project already has %s", what)
            end
            implementations = struct();
            if ismember("python", languages)
                implementations.python = char(adapterId + "_adapter:" + className);
            end
            if ismember("matlab", languages)
                implementations.matlab = char(className);
            end
            entry = nansen.internal.schemaEntry("nansen.fileAdapter");
            document = struct("schemaType", 'nansen.fileAdapter', "schemaVersion", char(entry.version), "id", char(adapterId), ...
                "version", '0.1.0', "title", char(title), "implementations", implementations);
            if ~isempty(extensions)
                document.extensions = cellstr(extensions);
            end
            nansen.checkDocument(document, ExpectedType="nansen.fileAdapter");
            shownExtensions = "its";
            if ~isempty(extensions)
                shownExtensions = strjoin(extensions, ", ");
            end
            tokens = ["__ID__", "__CLASS__", "__TITLE__", "__EXTENSIONS__"];
            values = [adapterId, className, replace(title, """", "'"), shownExtensions];
            for i = 1:numel(paths)
                folder = fileparts(paths(i));
                if ~isfolder(folder)
                    mkdir(folder);
                end
                if templates(i) == ""
                    nansen.internal.writeJson(paths(i), document)
                    continue
                end
                text = string(nansen.internal.readText(fullfile(nansen.internal.repoRoot(), "templates", templates(i))));
                for k = 1:numel(tokens)
                    text = replace(text, tokens(k), values(k));
                end
                nansen.internal.writeText(paths(i), text);
            end
            rehash
            obj.AdapterCache = [];
            result = document;
            result.files = cellstr(relative);
        end

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

        function removeModule(obj, moduleId)
            %removeModule Take a module off the project's list; module-in-use while the project uses what it provides
            moduleId = string(moduleId);
            entries = nansen.internal.asCellOfStructs(nansen.internal.getField(obj.Document, "modules", []));
            keep = ~cellfun(@(e) string(e.id) == moduleId, entries);
            if all(keep)
                nansen.internal.throwError("unknown-module", "the project does not list module '%s'", moduleId)
            end
            prefix = moduleId + ".";
            users = strings(1, 0);
            for entry = obj.Document.entityTypes
                for fragment = string(nansen.internal.asCellstr(nansen.internal.getField(entry{1}, "fragments", {})))
                    if startsWith(fragment, prefix)
                        users(end + 1) = string(entry{1}.name) + " (" + fragment + ")"; %#ok<AGROW>
                    end
                end
            end
            for variable = obj.dataVariables()
                if startsWith(variable.FileAdapter, prefix)
                    users(end + 1) = "data variable " + variable.Name + " (" + variable.FileAdapter + ")"; %#ok<AGROW>
                end
            end
            for pipeline = obj.pipelines()
                if obj.pipelineSource(string(pipeline{1}.id)) == "project"
                    for step = nansen.internal.asCellOfStructs(pipeline{1}.steps)
                        if startsWith(string(step{1}.method), prefix)
                            users(end + 1) = "pipeline " + string(pipeline{1}.id) + " (" + string(step{1}.method) + ")"; %#ok<AGROW>
                        end
                    end
                end
            end
            if ~isempty(users)
                nansen.internal.throwError("module-in-use", "module '%s' is used by %s", moduleId, strjoin(users, ", "))
            end
            document = obj.Document;
            document.modules = entries(keep);
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

        function method = createMethod(obj, methodId, options)
            %createMethod Start a method of the project: its document in methods/ and, for each language,
            %   a file to fill in (python/<id>.py with run(), matlab/<id>.m), from the templates that ship with NANSEN
            arguments
                obj
                methodId (1,1) string
                options.Title (1,1) string = ""
                options.EntityType (1,1) string = "*"
                options.Description (1,1) string = ""
                options.BatchMode (1,1) string = "serial"
                options.Languages (1,:) string = ["python", "matlab"]
                options.Queueable (1,1) logical = true
                options.Computes = {}   % columns (structs: name, dataType, title...) of a computed fragment it fills
            end
            computes = nansen.internal.asCellOfStructs(options.Computes);
            if isempty(regexp(methodId, "^[a-z][a-z0-9_]*$", "once"))
                nansen.internal.throwError("invalid-params", "a project method's id is a lower-case letter, then letters, digits or _")
            end
            if ~ismember(options.EntityType, ["*", "@project"])
                obj.entityType(options.EntityType);
            end
            if ~ismember(options.BatchMode, ["serial", "batch"])
                nansen.internal.throwError("invalid-params", "batchMode is serial or batch")
            end
            languages = unique(options.Languages, "stable");
            if isempty(languages) || ~all(ismember(languages, ["python", "matlab"]))
                nansen.internal.throwError("invalid-params", "languages are python and/or matlab")
            end
            title = strjoin(split(strtrim(options.Title))', " ");
            if title == ""
                title = methodId;
            end
            description = strjoin(split(strtrim(options.Description))', " ");
            documentPath = string(fullfile(obj.Folder, "methods", methodId + ".method.nansen.json"));
            paths = documentPath;
            templates = "";
            if ismember("python", languages)
                paths(end + 1) = string(fullfile(obj.Folder, "python", methodId + ".py"));
                templates(end + 1) = "method.py.template";
            end
            if ismember("matlab", languages)
                paths(end + 1) = string(fullfile(obj.Folder, "matlab", methodId + ".m"));
                templates(end + 1) = "method.m.template";
            end
            fragment = [];
            if ~isempty(computes)   % a computed column, as dev's table variables with an update function
                if ismember(options.EntityType, ["*", "@project"]) || options.BatchMode ~= "serial"
                    nansen.internal.throwError("invalid-params", "a method that computes columns runs on one entity type, once per entity")
                end
                entry = nansen.internal.schemaEntry("nansen.fragment");
                fragment = struct("schemaType", 'nansen.fragment', "schemaVersion", char(entry.version), "id", char(methodId), ...
                    "version", '1.0.0', "title", char(title), "columns", {computes}, "compute", struct("method", char(methodId)));
                fragment = nansen.checkDocument(fragment, ExpectedType="nansen.fragment");
                names = string(cellfun(@(c) char(c.name), computes, UniformOutput=false));
                clash = sort(intersect(obj.table(options.EntityType).columnNames(), names));
                if ~isempty(clash)
                    nansen.internal.throwError("column-exists", "%s already has column(s) %s", options.EntityType, strjoin(clash, ", "))
                end
                known = obj.fragments();
                if any(cellfun(@(f) f.Id == methodId, known))
                    nansen.internal.throwError("fragment-exists", "the project already has a fragment '%s'", methodId)
                end
                paths(end + 1) = string(obj.fragmentPath(methodId));
                templates(end + 1) = "fragment";
            end
            existing = paths(isfile(paths));
            if ~isempty(existing) || ismember(methodId, [obj.entityMethods().Id])
                if isempty(existing)
                    what = "a method '" + methodId + "'";
                else
                    what = strjoin(erase(replace(existing, "\", "/"), replace(string(obj.Folder), "\", "/") + "/"), ", ");
                end
                nansen.internal.throwError("method-exists", "the project already has %s", what)
            end
            implementations = struct();
            if ismember("python", languages)
                implementations.python = char(methodId + ":run");
            end
            if ismember("matlab", languages)
                implementations.matlab = char(methodId);
            end
            entry = nansen.internal.schemaEntry("nansen.method");
            document = struct("schemaType", 'nansen.method', "schemaVersion", char(entry.version), "id", char(methodId), ...
                "version", '0.1.0', "title", char(title), "entityType", char(options.EntityType), ...
                "batchMode", char(options.BatchMode), "implementations", implementations, ...
                "options", struct("type", 'object', "properties", struct()));
            if description ~= ""
                document.description = char(description);
            end
            if ~options.Queueable
                document.queueable = false;   % run by hand only, for example an interactive one
            end
            nansen.checkDocument(document, ExpectedType="nansen.method");
            batch = options.BatchMode == "batch";
            if options.EntityType == "@project"
                argument = "project";
                help = "project is the project it runs on: project.entities(entity_type), project.table(entity_type).";
                helpM = "project is the project it runs on: project.entities(entityType), project.table(entityType).";
            elseif batch
                argument = "entities";
                help = "entities are the entities it runs on, all at once (each with .key, .values, .locations, .load(name)).";
                helpM = "entities is a cell row of the entities it runs on, all at once (each with .Key, .values(), .locations(), .load(name)).";
            else
                argument = "entity";
                help = "entity is the entity it runs on: entity.key, entity.values, entity.locations, entity.load(name).";
                helpM = "entity is the entity it runs on: entity.Key, entity.values(), entity.locations(), entity.load(name).";
            end
            if description == ""
                shownDescription = title;
            else
                shownDescription = description;
            end
            resultM = "struct()";
            resultPy = "{}";
            if ~isempty(computes)
                names = string(cellfun(@(c) char(c.name), computes, UniformOutput=false));
                resultM = "struct(" + strjoin("""" + names + """, []", ", ") + ")";
                resultPy = "{" + strjoin("""" + names + """: None", ", ") + "}  # a value per column";
            end
            tokens = ["__ID__", "__TITLE__", "__DESCRIPTION__", "__ARG_HELP_M__", "__ARG_HELP__", "__ARG__", "__RESULT_M__", "__RESULT__"];
            values = [methodId, replace(title, """", "'"), shownDescription, helpM, help, argument, resultM, resultPy];
            for i = 1:numel(paths)
                folder = fileparts(paths(i));
                if ~isfolder(folder)
                    mkdir(folder);
                end
                if templates(i) == ""
                    nansen.internal.writeJson(paths(i), document)
                    continue
                elseif templates(i) == "fragment"
                    nansen.internal.writeJson(paths(i), fragment)
                    continue
                end
                text = string(nansen.internal.readText(fullfile(nansen.internal.repoRoot(), "templates", templates(i))));
                for k = 1:numel(tokens)
                    text = replace(text, tokens(k), values(k));
                end
                nansen.internal.writeText(paths(i), text);
            end
            rehash   % a new file in a folder already on the path is seen at once
            if ~isempty(computes)
                obj.attachFragment(options.EntityType, methodId);
            end
            method = obj.method(methodId);
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
            stepMethods = containers.Map("KeyType", "char", "ValueType", "any");   % looked up once, not per row
            for candidate = obj.pipelines(entityType)
                known(char(string(candidate{1}.id))) = candidate{1};
                for step = nansen.internal.asCellOfStructs(candidate{1}.steps)
                    methodId = char(string(step{1}.method));
                    if ~isKey(stepMethods, methodId)
                        stepMethods(methodId) = obj.method(string(methodId));
                    end
                end
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
                    method = stepMethods(methodId);
                    title = nansen.internal.getField(stepList{s}, "title", '');
                    if isempty(title)
                        title = char(method.Title);
                    end
                    finished = [];
                    if isKey(done, methodId)
                        finished = done(methodId);
                        count = count + 1;
                    end
                    steps{s} = struct("title", char(title), "method", methodId, "queueable", method.Queueable, ...
                        "done", isKey(done, methodId), "finishedAt", finished);
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
            %presets Option sets of a method: a cell row of structs (name, description, values, source)
            %
            %   The implicit default (the schema's defaults), the project's saved
            %   ones, then those its modules ship that the project has none of the
            %   same name of. source is default, project or module (then with module).
            method = obj.method(methodId);
            presets = {struct("name", 'default', "description", 'The method''s defaults', "values", method.defaultOptions(), ...
                "source", 'default')};
            names = "default";
            folder = fullfile(obj.Folder, "options", methodId);
            if isfolder(folder)
                listing = dir(fullfile(folder, "*.options.nansen.json"));
                for name = sort(string({listing.name}))
                    doc = nansen.readDocument(fullfile(folder, name), ExpectedType="nansen.options");
                    presets{end + 1} = struct("name", doc.name, ...
                        "description", char(nansen.internal.getField(doc, "description", "")), "values", doc.values, ...
                        "source", 'project'); %#ok<AGROW>
                    names(end + 1) = string(doc.name); %#ok<AGROW>
                end
            end
            for module = obj.modules()
                for doc = module.presetDocuments()
                    if string(doc{1}.method.id) == string(methodId) && ~ismember(string(doc{1}.name), names)
                        presets{end + 1} = struct("name", doc{1}.name, ...
                            "description", char(nansen.internal.getField(doc{1}, "description", "")), "values", doc{1}.values, ...
                            "source", 'module', "module", char(module.Id)); %#ok<AGROW>
                        names(end + 1) = string(doc{1}.name); %#ok<AGROW>
                    end
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

        function found = tools(obj)
            %tools The project tools: methods that run once on the project (entityType @project), a row of nansen.Method
            found = obj.entityMethods();
            found = found(arrayfun(@(m) m.isTool(), found));
        end

        function result = runTool(obj, methodId, options)
            %runTool Run a project tool now, in this MATLAB session; returns what it returns
            arguments
                obj
                methodId (1,1) string
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
            result = nansen.runTool(method, obj, values, context);
        end

        function names = updateValues(obj, entity, values)
            %updateValues Write values (a struct) into the entity's table row, those of columns the table has
            %
            %   For a method that fills columns it does not compute. Returns the
            %   names written; unknown-entity for an entity the table has no row
            %   of. As Python's Project.update_values.
            table = obj.table(entity.EntityType);
            if ~table.hasRow(entity.Key)
                nansen.internal.throwError("unknown-entity", "%s %s has no row in the table", entity.EntityType, jsonencode(entity.Key))
            end
            names = nansen.Project.writableNames(table, values);
            if ~isempty(names)
                kept = struct();
                for name = names
                    kept.(name) = values.(name);
                end
                table.updateRow(entity.Key, kept);
                table.write();
            end
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

        function deleteDataVariable(obj, name)
            path = obj.dataVariablePath(string(name));
            if ~isfile(path)
                nansen.internal.throwError("unknown-data-variable", "the project has no data variable '%s'", name)
            end
            delete(path);
        end

        function patterns = levelPatterns(obj, variable)
            %levelPatterns File pattern names to patterns at the variable's entity level in its location
            patterns = obj.filePatterns(variable.DataLocation, variable.EntityType);
        end

        function patterns = filePatterns(obj, dataLocation, entityType)
            %filePatterns The named file patterns of the entity type's level in a data location (name -> pattern)
            patterns = containers.Map("KeyType", "char", "ValueType", "char");
            config = obj.requireDataset().Config;
            variable = struct("DataLocation", string(dataLocation), "EntityType", string(entityType));
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

        function paths = existingFiles(obj, entity, name)
            %existingFiles The files that hold the variable for the entity and exist
            %
            %   Where a scan found its folders, or else where save writes it, for a
            %   folder made since the last scan.
            variable = obj.dataVariable(name);
            paths = obj.dataPaths(entity, name);
            paths = paths(arrayfun(@isfile, paths));
            if isempty(paths) && variable.FilePattern == ""
                try
                    written = obj.writePath(entity, name);
                    if isfile(written)
                        paths = written;
                    end
                catch err
                    if ~isa(err, "nansen.NansenError")
                        rethrow(err)
                    end
                end
            end
        end

        function data = load(obj, entity, name, options)
            %load Read the variable for the entity with its file adapter
            %
            %   When a file pattern matches several files, an adapter that can
            %   open stacks (open) reads them as one recording, joined along the
            %   frames in natural order; any other reads the first. What was read
            %   is kept in obj.DataCache and given again until a file changes;
            %   load(..., Cached=false) reads the files and keeps nothing.
            arguments
                obj
                entity
                name (1,1) string
                options.Cached (1,1) logical = true
            end
            variable = obj.dataVariable(name);
            paths = obj.existingFiles(entity, name);
            if isempty(paths)
                nansen.internal.throwError("data-not-found", "%s has no '%s'", entity.EntityType, name)
            end
            adapter = obj.adapters().get(variable.FileAdapter);
            if numel(paths) > 1 && ismethod(adapter, "open")
                paths = nansen.internal.naturalOrder(paths);
                reader = @() all(adapter.open(paths));
            else
                paths = paths(1);
                reader = @() adapter.read(paths(1));
            end
            if ~options.Cached
                data = variable.inFile(reader(), paths(1));
                return
            end
            stamps = zeros(numel(paths), 2);
            for i = 1:numel(paths)
                info = dir(paths(i));
                stamps(i, :) = [info.datenum, info.bytes];
            end
            data = obj.DataCache.getOrLoad(nansen.Project.cacheKey(variable.FileAdapter, strjoin(paths, "|")), ...
                reshape(stamps.', 1, []), reader);
            data = variable.inFile(data, paths(1));
        end

        function stack = openStack(obj, entity, name)
            %openStack The variable as a nansen.Stack read a few frames at a time
            %
            %   An adapter with open reads only the frames asked for, and joins a
            %   recording kept in several files; for any other, the whole value is
            %   read (load) and given as a stack.
            variable = obj.dataVariable(name);
            paths = obj.existingFiles(entity, name);
            if isempty(paths)
                nansen.internal.throwError("data-not-found", "%s has no '%s'", entity.EntityType, name)
            end
            adapter = obj.adapters().get(variable.FileAdapter);
            if ismethod(adapter, "open")
                stack = adapter.open(nansen.internal.naturalOrder(paths));
                if ~isa(stack, "nansen.Stack")
                    stack = nansen.Stack.fromArray(stack);
                end
            else
                stack = nansen.Stack.fromArray(obj.load(entity, name));
            end
            stack.MaxFrames = obj.StackFrameLimit;
        end

        function [stack, adapterId, candidates] = openFileStack(obj, path, adapterId)
            %openFileStack Any file as a nansen.Stack, as dev's imviewer opens one
            %
            %   With the adapter given, or the first of those that read its
            %   extension as image stacks (AdapterRegistry.forStacks) that opens
            %   it. Returns the stack, the adapter's id and the candidates.
            arguments
                obj
                path (1,1) string
                adapterId (1,1) string = ""
            end
            [~, name, extension] = fileparts(path);
            candidates = obj.adapters().forStacks(extension);
            tries = candidates;
            if adapterId ~= ""
                tries = adapterId;
            end
            if isempty(tries)
                if extension == ""
                    extension = "these";
                end
                nansen.internal.throwError("unsupported-file", "no file adapter of the project reads %s files as image stacks", extension)
            end
            problems = strings(1, 0);
            for candidate = tries
                adapter = obj.adapters().get(candidate);
                try
                    if ismethod(adapter, "open")
                        stack = adapter.open(path);
                    else
                        stack = adapter.read(path);
                    end
                    if ~isa(stack, "nansen.Stack")
                        stack = nansen.Stack.fromArray(stack);
                    end
                catch err
                    if adapterId ~= "" || ~startsWith(string(err.identifier), "nansen:")
                        rethrow(err)
                    end
                    problems(end + 1) = candidate + ": " + string(err.message); %#ok<AGROW>
                    continue
                end
                stack.MaxFrames = obj.StackFrameLimit;
                adapterId = candidate;
                return
            end
            nansen.internal.throwError("invalid-data", "%s could not be read as a stack: %s", name + extension, strjoin(problems, "; "))
        end

        function writer = stackWriter(obj, entity, name, dimensions, className)
            %stackWriter A nansen.StackWriter of the variable as a stack of the given size, a chunk of frames at a time
            %
            %   An adapter with create writes each chunk to the file as it comes;
            %   for any other, the stack is kept in memory and written with write
            %   when the writer closes. An empty name writes nothing.
            if strlength(string(name)) == 0
                writer = nansen.StackWriter(dimensions, className);
                return
            end
            variable = obj.dataVariable(name);
            path = obj.writePath(entity, name);
            folder = fileparts(path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            adapter = obj.adapters().get(variable.FileAdapter);
            obj.DataCache.remove(nansen.Project.cacheKey(variable.FileAdapter, path));
            if ismethod(adapter, "create")
                writer = adapter.create(path, dimensions, className);
            else
                cache = obj.DataCache;
                key = nansen.Project.cacheKey(variable.FileAdapter, path);
                writer = nansen.StackWriter(dimensions, className, Finish=@(data) nansen.Project.writeAndForget(adapter, path, data, cache, key));
            end
        end

        function path = save(obj, entity, name, data)
            %save Write the variable for the entity, creating folders as needed; returns the path written
            %
            %   A variable the project does not have yet is made first, as
            %   dev's saveData makes one: of the entity's type, in the first
            %   data location that can be written, as <name>.npy for an array
            %   of numbers or truth values (more than one of them) and as
            %   <name>.json for anything else. As Python's Project.save.
            if ~isfile(obj.dataVariablePath(string(name)))
                obj.addDataVariable(obj.newVariableDocument(entity, name, data));
            end
            variable = obj.dataVariable(name);
            path = obj.writePath(entity, name);
            folder = fileparts(path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            adapter = obj.adapters().get(variable.FileAdapter);
            if variable.VariableInFile ~= ""   % one variable of the file: the others are kept
                others = struct();
                if isfile(path)
                    others = adapter.read(path);
                end
                if ~(isstruct(others) && isscalar(others))
                    nansen.internal.throwError("invalid-data", "%s does not hold named variables; '%s' cannot be one of them", path, name)
                end
                others.(variable.VariableInFile) = data;
                data = others;
            end
            adapter.write(path, data);
            obj.DataCache.remove(nansen.Project.cacheKey(variable.FileAdapter, path));   % a rewrite in the same tick keeps the time
        end

        function document = newVariableDocument(obj, entity, name, data)
            %newVariableDocument The data variable save makes for a value of a name the project does not have
            writable = string.empty;
            for location = obj.requireDataset().Config.locations()
                if string(nansen.internal.getField(location{1}, "access", "read")) == "readwrite"
                    writable(end + 1) = string(location{1}.identifier); %#ok<AGROW>
                end
            end
            if isempty(writable)
                nansen.internal.throwError("unknown-data-variable", "no data variable '%s', and no data location can be written to make one", name)
            end
            extension = ".json";
            adapter = "json";
            if (isnumeric(data) || islogical(data)) && numel(data) > 1
                extension = ".npy";
                adapter = "npy";
            end
            entry = nansen.internal.schemaEntry("nansen.dataVariable");
            document = struct("schemaType", 'nansen.dataVariable', "schemaVersion", char(entry.version), "name", char(name), ...
                "entityType", char(entity.EntityType), "dataLocation", char(writable(1)), ...
                "fileName", char(string(name) + extension), "fileAdapter", char(adapter));
        end

        function status = dataStatus(obj, entity)
            %dataStatus Each data variable of the entity's type: whether a file exists, and where
            status = {};
            for variable = obj.dataVariables(entity.EntityType)
                try
                    files = obj.existingFiles(entity, variable.Name);
                catch err
                    if ~isa(err, "nansen.NansenError")
                        rethrow(err)
                    end
                    files = strings(1, 0);
                end
                status{end + 1} = struct("name", char(variable.Name), "dataLocation", char(variable.DataLocation), ...
                    "fileAdapter", char(variable.FileAdapter), ...
                    "dataType", nansen.internal.getField(variable.Document, "dataType", []), ...
                    "files", {cellstr(files)}); %#ok<AGROW>
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

        function path = viewsPath(obj, entityType)
            path = string(fullfile(obj.Folder, "views", entityType + ".views.nansen.json"));
        end

        function views = views(obj, entityType)
            %views The saved views of an entity type's table (an nansen.Views)
            arguments
                obj
                entityType (1,1) string
            end
            obj.entityType(entityType);
            views = nansen.Views(obj.viewsPath(entityType), entityType, obj.table(entityType).Key);
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

        function fragment = saveFragment(obj, document)
            %saveFragment Change a project fragment's definition: titles, descriptions, units, defaults and choices
            %
            %   Its columns keep their names, types and order, so the values in the
            %   tables stay as they are; new choices must allow the values there.
            %   The version goes up (a patch step unless a higher one is given), and
            %   every table holding the fragment records it.
            arguments
                obj
                document (1,1) struct
            end
            document = nansen.checkDocument(document, ExpectedType="nansen.fragment");
            new = nansen.Fragment(document);
            path = obj.fragmentPath(new.Id);
            if ~isfile(path)
                obj.fragment(new.Id);   % unknown-fragment
                nansen.internal.throwError("fragment-read-only", "fragment '%s' comes from a module; only the project's own can be changed", new.Id)
            end
            old = nansen.Fragment.read(path);
            if ~isequal([old.Columns.Name], [new.Columns.Name]) || ~isequal([old.Columns.DataType], [new.Columns.DataType])
                nansen.internal.throwError("fragment-mismatch", "the columns of %s keep their names, types and order when it is changed", new.Id)
            end
            oldParts = double(split(old.Version, "."))';
            newParts = double(split(new.Version, "."))';
            difference = find(newParts ~= oldParts, 1);
            if ~isempty(difference) && newParts(difference) < oldParts(difference)
                nansen.internal.throwError("invalid-params", "%s is at %s; it cannot go back to %s", new.Id, old.Version, new.Version)
            end
            version = new.Version;
            if isempty(difference)
                newParts(end) = newParts(end) + 1;
                version = strjoin(string(newParts), ".");
            end
            users = strings(1, 0);
            for entry = obj.Document.entityTypes
                listed = string(nansen.internal.asCellstr(nansen.internal.getField(entry{1}, "fragments", {})));
                if ismember(new.Id, listed)
                    users(end + 1) = string(entry{1}.name); %#ok<AGROW>
                end
            end
            tables = cell(1, numel(users));
            columns = nansen.internal.asCellOfStructs(document.columns);
            for i = 1:numel(users)
                tables{i} = obj.table(users(i));
                for c = 1:numel(columns)
                    if ~isfield(columns{c}, "choices")
                        continue
                    end
                    values = string(tables{i}.Data.(columns{c}.name));
                    values = values(~ismissing(values));
                    stray = unique(values(~ismember(values, string(nansen.internal.asCellstr(columns{c}.choices)))));
                    if ~isempty(stray)
                        nansen.internal.throwError("invalid-value", "%s rows hold %s in '%s', which the choices leave out", ...
                            users(i), strjoin(stray(1:min(5, end)), ", "), columns{c}.name)
                    end
                end
            end
            document.version = char(version);
            document = nansen.checkDocument(document, ExpectedType="nansen.fragment");
            nansen.internal.writeJson(path, document)
            for i = 1:numel(tables)
                tables{i}.setFragmentVersion(new.Id, version);
                tables{i}.write();
            end
            fragment = nansen.Fragment(document);
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

        function writeAssignments(obj, assignments)
            entry = nansen.internal.schemaEntry("nansen.assignments");
            document = struct("schemaType", 'nansen.assignments', "schemaVersion", char(entry.version), ...
                "assignments", {reshape(assignments, 1, [])});
            nansen.checkDocument(document, ExpectedType="nansen.assignments");
            nansen.internal.writeJson(obj.assignmentsPath(), document)
        end
    end

    methods (Static, Access = private)
        function writeAndForget(adapter, path, data, cache, key)
            adapter.write(path, data);
            cache.remove(key);
        end

        function key = cacheKey(adapterId, path)
            % One entry per file and file adapter
            key = string(adapterId) + "|" + string(path);
        end
    end

    methods (Static)
        function names = writableNames(table, values)
            %writableNames The fields of values that are columns of the table and not of its key, in their order
            names = string(fieldnames(values))';
            names = names(ismember(names, table.columnNames()) & ~ismember(names, table.Key));
        end

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
