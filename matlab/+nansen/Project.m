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
    end

    properties (Access = private)
        DatasetCache = []
        AdapterCache = []
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
            path = obj.fragmentPath(fragmentId);
            if ~isfile(path)
                nansen.internal.throwError("unknown-fragment", "fragment '%s' is not defined (%s)", fragmentId, path)
            end
            fragment = nansen.Fragment.read(path);
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

        function dataset = requireDataset(obj)
            dataset = obj.dataset();
            if isempty(dataset)
                nansen.internal.throwError("no-dataset", "project '%s' has no dataset", obj.Name)
            end
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
                table.addRow(entity.Key)
                added{end + 1} = entity.Key; %#ok<AGROW>
            end
            if ~isempty(added)
                table.write()
            end
        end

        % -- data variables and file adapters ------------------------------------------

        function registry = adapters(obj)
            %adapters Built-in file adapters plus those declared in file-adapters/
            if isempty(obj.AdapterCache)
                registry = nansen.AdapterRegistry();
                folder = fullfile(obj.Folder, "file-adapters");
                if isfolder(folder)
                    listing = dir(fullfile(folder, "*.fileAdapter.nansen.json"));
                    for name = sort(string({listing.name}))
                        registry.declare(nansen.readDocument(fullfile(folder, name), ...
                            ExpectedType="nansen.fileAdapter"), folder);
                    end
                end
                obj.AdapterCache = registry;
            end
            registry = obj.AdapterCache;
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

        function data = load(obj, entity, name)
            %load Read the variable for the entity with its file adapter (the first file when several match)
            variable = obj.dataVariable(name);
            paths = obj.dataPaths(entity, name);
            paths = paths(arrayfun(@isfile, paths));
            if isempty(paths)
                nansen.internal.throwError("data-not-found", "%s has no '%s'", entity.EntityType, name)
            end
            data = obj.adapters().get(variable.FileAdapter).read(paths(1));
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

    methods (Static)
        function obj = create(folder, name, options)
            %create Make a project folder with an empty project file, fragments/ and tables/
            %
            %   Dataset is the path of a DSM config, relative to the folder.
            arguments
                folder (1,1) string
                name (1,1) string
                options.Title (1,1) string = ""
                options.Dataset (1,1) string = ""
            end
            if isfile(fullfile(folder, nansen.Project.ProjectFile))
                error("nansen:Project:Exists", "%s already holds a project", folder)
            end
            entry = nansen.internal.schemaEntry("nansen.project");
            document = struct("schemaType", 'nansen.project', "schemaVersion", char(entry.version), "name", char(name));
            if options.Title ~= ""
                document.title = char(options.Title);
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
