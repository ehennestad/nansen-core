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

        function settings = settings(obj)
            %settings The user's app settings, with the defaults for those not set
            settings = nansen.Catalog.defaultSettings();
            stored = nansen.internal.getField(obj.read(), "settings", struct());
            for group = string(fieldnames(settings))'
                if isfield(stored, group)
                    for name = string(fieldnames(stored.(group)))'
                        settings.(group).(name) = stored.(group).(name);
                    end
                end
            end
        end

        function settings = saveSettings(obj, changes)
            %saveSettings Change some settings (a partial settings struct); returns them all
            document = obj.read();
            stored = nansen.internal.getField(document, "settings", struct());
            for group = string(fieldnames(changes))'
                if ~isstruct(changes.(group)) || ~isscalar(changes.(group))
                    nansen.internal.throwError("invalid-params", "settings.%s must be an object", group)
                end
                values = nansen.internal.getField(stored, group, struct());
                for name = string(fieldnames(changes.(group)))'
                    values.(name) = changes.(group).(name);
                end
                stored.(group) = values;
            end
            document.settings = stored;
            try
                obj.write(document);
            catch err
                if isa(err, "nansen.NansenError")
                    nansen.internal.throwError("invalid-params", "settings: %s", err.message)
                end
                rethrow(err)
            end
            settings = obj.settings();
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

        function entry = relocate(obj, path, newPath)
            %relocate Point an entry at the folder its project was moved to; the project there must have the entry's name
            document = obj.read();
            path = nansen.Catalog.absolute(path);
            entries = nansen.internal.asCellOfStructs(document.projects);
            index = find(cellfun(@(p) string(p.path) == path, entries), 1);
            if isempty(index)
                nansen.internal.throwError("unknown-project", "%s is not in the catalog", path)
            end
            newPath = nansen.Catalog.absolute(newPath);
            projectFile = fullfile(newPath, "project.nansen.json");
            if ~isfile(projectFile)
                nansen.internal.throwError("file-not-found", "%s holds no project.nansen.json", newPath)
            end
            found = nansen.readDocument(projectFile, ExpectedType="nansen.project");
            if string(found.name) ~= string(entries{index}.name)
                nansen.internal.throwError("invalid-params", "%s holds project '%s', not '%s'", newPath, found.name, entries{index}.name)
            end
            entries{index}.path = char(newPath);
            keep = true(1, numel(entries));
            for i = 1:numel(entries)
                keep(i) = i == index || string(entries{i}.path) ~= newPath;
            end
            entry = entries{index};
            document.projects = entries(keep);
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
        function settings = defaultSettings()
            settings = struct("queue", struct("autoStart", true, "worker", 'thread'), "addons", struct("folder", ""), ...
                "workers", struct("python", "", "matlab", ""));
        end

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
