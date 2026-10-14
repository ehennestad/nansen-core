classdef Catalog
%Catalog The projects a user has opened, kept in a file the app is given
%
%   catalog = nansen.Catalog(path). nansen.Catalog.defaultPath() is where
%   the app keeps it for this user; the core never reads it on its own.

    properties (SetAccess = private)
        Path (1,1) string
    end

    methods
        function obj = Catalog(path)
            arguments
                path (1,1) string
            end
            obj.Path = path;
        end

        function projects = projects(obj)
            %projects Projects, most recently opened first, each with whether its folder still holds a project
            projects = nansen.internal.asCellOfStructs(obj.read().projects);
            if isempty(projects)
                return
            end
            % Entries are appended when added, so of two opened in the same second the later one is last
            projects = flip(projects);
            opened = cellfun(@(p) string(nansen.internal.getField(p, "lastOpened", "")), projects);
            [~, order] = sort(opened, "descend");
            projects = projects(order);
            for i = 1:numel(projects)
                projects{i}.available = isfile(fullfile(projects{i}.path, "project.nansen.json"));
            end
        end

        function entry = add(obj, project, opened)
            %add Record a project (an nansen.Project); updates the entry for the same folder
            arguments
                obj
                project
                opened (1,1) logical = true
            end
            document = obj.read();
            path = nansen.Catalog.absolute(project.Folder);
            entry = struct("name", char(project.Name), "title", char(project.Title), "path", char(path));
            if opened
                entry.lastOpened = char(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss"));
            end
            entries = nansen.internal.asCellOfStructs(document.projects);
            entries = entries(~cellfun(@(p) string(p.path) == path, entries));
            entries{end + 1} = entry;
            document.projects = entries;
            obj.write(document)
        end

        function remove(obj, path)
            document = obj.read();
            path = nansen.Catalog.absolute(path);
            entries = nansen.internal.asCellOfStructs(document.projects);
            keep = ~cellfun(@(p) string(p.path) == path, entries);
            if all(keep)
                nansen.internal.throwError("unknown-project", "%s is not in the catalog", path)
            end
            document.projects = entries(keep);
            obj.write(document)
        end
    end

    methods (Access = private)
        function document = read(obj)
            if ~isfile(obj.Path)
                entry = nansen.internal.schemaEntry("nansen.catalog");
                document = struct("schemaType", 'nansen.catalog', "schemaVersion", char(entry.version), "projects", {{}});
                return
            end
            document = nansen.readDocument(obj.Path, ExpectedType="nansen.catalog");
        end

        function write(obj, document)
            folder = fileparts(obj.Path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            document = nansen.checkDocument(document, ExpectedType="nansen.catalog");
            nansen.internal.writeJson(obj.Path, document)
        end
    end

    methods (Static)
        function path = defaultPath()
            %defaultPath Where the app keeps the catalog for this user (the same file Python uses)
            if ispc
                base = string(getenv("APPDATA"));
            elseif ismac
                base = string(fullfile(getenv("HOME"), "Library", "Application Support"));
            else
                base = string(getenv("XDG_CONFIG_HOME"));
                if base == ""
                    base = string(fullfile(getenv("HOME"), ".config"));
                end
            end
            path = string(fullfile(base, "nansen", "catalog.nansen.json"));
        end

        function path = absolute(path)
            %absolute An absolute path without a trailing separator
            path = string(path);
            if ~nansen.internal.isAbsolutePath(path)
                path = string(fullfile(pwd, path));
            end
            path = regexprep(path, "[\\/]+$", "");
        end
    end
end
