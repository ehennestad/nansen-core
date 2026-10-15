classdef Dataset < handle
%Dataset A project's Dataset Structure Model config, with root paths resolved
%
%   dataset = nansen.Dataset.load(path) loads and validates a DSM config
%   (applying its .local.json overlay). Relative root paths are resolved
%   against the config's folder. Needs the DSM MATLAB reader (+dsm) on the
%   path.

    properties (SetAccess = private)
        Config  % dsm.Config
        Folder (1,1) string
        Environment (1,1) string = ""
    end

    methods
        function obj = Dataset(config, folder, environment)
            arguments
                config (1,1) dsm.Config
                folder (1,1) string
                environment (1,1) string = ""
            end
            obj.Config = config;
            obj.Folder = folder;
            if environment == ""
                environment = string(nansen.internal.getField(config.preferences(), "environmentIdentifier", ""));
            end
            obj.Environment = environment;
        end

        % -- entity types and keys ------------------------------------------------------

        function names = entityTypes(obj)
            names = obj.Config.entityTypes();
        end

        function keys = identityKeys(obj, entityType)
            keys = obj.Config.identityKeys(entityType);
        end

        function types = ancestorTypes(obj, entityType)
            %ancestorTypes Entity types whose identity is part of this type's key
            types = strings(1, 0);
            for location = obj.Config.locationIds()
                index = obj.Config.entityLevelIndex(location, entityType);
                if isempty(index)
                    continue
                end
                levels = obj.Config.layout(location);
                levelTypes = strings(1, 0);
                for i = 1:index - 1
                    levelType = string(nansen.internal.getField(levels{i}, "entityType", ""));
                    if levelType ~= ""
                        levelTypes(end + 1) = levelType; %#ok<AGROW>
                    end
                end
                types = [types, levelTypes]; %#ok<AGROW>
                for candidate = obj.Config.typesBefore(entityType)
                    if ~ismember(candidate, levelTypes) && ~isempty(obj.Config.rulesFor(location, candidate))
                        types(end + 1) = candidate; %#ok<AGROW>
                    end
                end
            end
            types = unique(types);
            order = arrayfun(@(t) obj.Config.typeOrder(t), types);
            [~, sorting] = sort(order);
            types = reshape(types(sorting), 1, []);
        end

        function columns = keyColumns(obj, entityType)
            %keyColumns The key as nansen.Column objects: ancestors' identity, outermost first, then the type's own
            names = strings(1, 0);
            for ancestor = obj.ancestorTypes(entityType)
                names = [names, obj.identityKeys(ancestor)]; %#ok<AGROW>
            end
            names = [names, obj.identityKeys(entityType)];
            definitions = obj.Config.definitions();
            columns = nansen.Column.empty(1, 0);
            for name = names
                dataType = "string";
                if string(definitions.(name).dataType) == "integer"
                    dataType = "integer";
                end
                columns(end + 1) = nansen.Column(name, dataType); %#ok<AGROW>
            end
        end

        function key = recordKey(~, record)
            %recordKey The key values of a record: its parents' identity, then its own, as a struct
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

        % -- roots ------------------------------------------------------------------------

        function roots = roots(obj)
            %roots Every root storage path in the active environment, resolved on this machine
            roots = struct("DataLocation", {}, "RootStoragePath", {}, "Path", {}, ...
                "Environment", {}, "Priority", {}, "Available", {});
            for location = obj.Config.locationIds()
                entries = nansen.internal.asCellOfStructs(obj.Config.filesystem(location).rootStoragePaths);
                for i = 1:numel(entries)
                    entry = entries{i};
                    environment = string(nansen.internal.getField(entry, "environment", ""));
                    if obj.Environment ~= "" && environment ~= "" && environment ~= obj.Environment
                        continue
                    end
                    path = string(entry.path);
                    if ~nansen.internal.isAbsolutePath(path)
                        % Relative to the config's folder, with "." and ".." resolved: dir() reports
                        % folders without them, so a walk could not tell its entries are under this root.
                        path = replace(nansen.internal.normalizePath(fullfile(obj.Folder, path)), "/", filesep);
                    end
                    volume = string(nansen.internal.getField(entry, "volumeName", ""));
                    if ~isfolder(path) && volume ~= ""
                        % A removable drive mounted somewhere else now (another drive letter, say)
                        inside = nansen.internal.pathInVolume(string(entry.path), volume);
                        if ~ismissing(inside)
                            for mount = nansen.internal.volumeMounts(volume)
                                candidate = mount;
                                if inside ~= ""
                                    candidate = string(fullfile(mount, inside));
                                end
                                if isfolder(candidate)
                                    path = candidate;
                                    break
                                end
                            end
                        end
                    end
                    roots(end + 1) = struct("DataLocation", location, "RootStoragePath", string(entry.identifier), ...
                        "Path", path, "Environment", environment, ...
                        "Priority", nansen.internal.getField(entry, "priority", 0), "Available", isfolder(path)); %#ok<AGROW>
                end
            end
        end

        function root = root(obj, dataLocation, rootStoragePath)
            %root A root of the location: the named one, or the available one with the lowest priority number
            arguments
                obj
                dataLocation (1,1) string
                rootStoragePath (1,1) string = ""
            end
            roots = obj.roots();
            roots = roots([roots.DataLocation] == dataLocation);
            if rootStoragePath ~= ""
                roots = roots([roots.RootStoragePath] == rootStoragePath);
            end
            if isempty(roots)
                nansen.internal.throwError("unknown-location", ...
                    "no root for data location '%s' in this environment", dataLocation)
            end
            [~, order] = sortrows([~[roots.Available]', [roots.Priority]']);
            root = roots(order(1));
        end

        function [listing, summary] = listing(obj)
            %listing Snapshot every available root; summary describes each root
            roots = {};
            summary = {};
            for info = obj.roots()
                item = struct("dataLocation", char(info.DataLocation), "rootStoragePath", char(info.RootStoragePath), ...
                    "path", char(info.Path), "available", info.Available);
                if info.Available
                    root = dsm.listing.fromDirectory(info.DataLocation, info.RootStoragePath, info.Path);
                    roots{end + 1} = root; %#ok<AGROW>
                    item.entries = numel(root.Entries);
                end
                summary{end + 1} = item; %#ok<AGROW>
            end
            listing = dsm.Listing(roots, obj.Environment);
        end

        function result = scan(obj, listing, registry)
            %scan Walk the stores, or a given dsm.Listing snapshot
            arguments
                obj
                listing = []
                registry (1,1) dsm.ExtractorRegistry = dsm.ExtractorRegistry()
            end
            if isempty(listing)
                [listing, summary] = obj.listing();
            else
                summary = cellfun(@(r) struct("dataLocation", char(r.DataLocation), ...
                    "rootStoragePath", char(r.RootStoragePath), "available", true, "entries", numel(r.Entries)), ...
                    listing.Roots, UniformOutput=false);
            end
            walked = dsm.walk(obj.Config, listing, registry);
            document = nansen.internal.jsonRoundTrip(walked.toStruct());
            environment = listing.Environment;
            if environment == ""
                environment = obj.Environment;
            end
            stamp = string(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss"));
            result = nansen.Scan(nansen.internal.asCellOfStructs(document.records), ...
                nansen.internal.asCellOfStructs(document.unmatched), summary, environment, stamp);
        end

        % -- writing ----------------------------------------------------------------------

        function path = generatePath(obj, dataLocation, entityType, values)
            %generatePath The path a new entity takes in a readwrite location (DSM generation)
            try
                path = dsm.generatePath(obj.Config, dataLocation, entityType, values);
            catch err
                if isa(err, "dsm.GenerationError")
                    nansen.internal.throwError("generation-failed", "[%s] %s", err.Code, err.message)
                end
                rethrow(err)
            end
        end

        function path = absolute(obj, dataLocation, relative, rootStoragePath)
            arguments
                obj
                dataLocation (1,1) string
                relative (1,1) string
                rootStoragePath (1,1) string = ""
            end
            path = string(fullfile(obj.root(dataLocation, rootStoragePath).Path, relative));
        end
    end

    methods (Static)
        function obj = load(path, environment)
            arguments
                path (1,1) string
                environment (1,1) string = ""
            end
            if ~isfile(path)
                nansen.internal.throwError("file-not-found", "File not found: %s", path)
            end
            try
                config = dsm.loadConfig(path);
            catch err
                if isa(err, "dsm.ConfigError")
                    nansen.internal.throwError("dataset-invalid", "%s: %s", path, err.message)
                end
                rethrow(err)
            end
            obj = nansen.Dataset(config, string(fileparts(path)), environment);
        end
    end
end
