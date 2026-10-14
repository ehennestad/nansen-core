classdef Project < handle
%Project A project folder (docs/reference/project-layout.md)
%
%   project = nansen.Project.create(folder, name) makes a new project and
%   project = nansen.Project.open(folder) opens one. Nothing records a
%   "current" project: code that needs a project is given one.

    properties (SetAccess = private)
        Folder (1,1) string
        Document struct
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
        function obj = Project(folder, document)
            %Project Wrap a folder and its decoded project document; use create or open instead
            arguments
                folder (1,1) string
                document (1,1) struct
            end
            obj.Folder = folder;
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
            arguments
                obj
                name (1,1) string
                key (1,:) nansen.Column
                options.Fragments (1,:) string = string.empty(1, 0)
                options.Title (1,1) string = ""
            end
            if ismember(name, obj.EntityTypes)
                error("nansen:Project:EntityTypeExists", "Entity type '%s' already exists", name)
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
            arguments
                folder (1,1) string
                name (1,1) string
                options.Title (1,1) string = ""
            end
            if isfile(fullfile(folder, nansen.Project.ProjectFile))
                error("nansen:Project:Exists", "%s already holds a project", folder)
            end
            entry = nansen.internal.schemaEntry("nansen.project");
            document = struct("schemaType", 'nansen.project', "schemaVersion", char(entry.version), "name", char(name));
            if options.Title ~= ""
                document.title = char(options.Title);
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

        function obj = open(folder)
            arguments
                folder (1,1) string
            end
            document = nansen.readDocument(fullfile(folder, nansen.Project.ProjectFile), ExpectedType="nansen.project");
            obj = nansen.Project(folder, document);
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
