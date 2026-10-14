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
            obj.save(document)
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
        function save(obj, document)
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
            obj.save(obj.Document)
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
