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

        function result = scan(obj, listing, registry, assignments)
            %scan Walk the stores, or a given dsm.Listing snapshot
            %
            %   assignments (a cell row of the structs of a nansen.assignments) are
            %   entries matched to an entity by hand: each is that entity, whatever
            %   its name, and what lies below it is walked as usual. Those that no
            %   longer fit the config (another level, another key) are left out.
            arguments
                obj
                listing = []
                registry (1,1) dsm.ExtractorRegistry = dsm.ExtractorRegistry()
                assignments (1,:) cell = {}
            end
            if isempty(listing)
                [listing, summary] = obj.listing();
            else
                summary = cellfun(@(r) struct("dataLocation", char(r.DataLocation), ...
                    "rootStoragePath", char(r.RootStoragePath), "available", true, "entries", numel(r.Entries)), ...
                    listing.Roots, UniformOutput=false);
            end
            plans = obj.assignmentPlans(assignments);
            derived = {};
            if ~isempty(plans)
                [listing, derived] = obj.splitListing(listing, plans);
            end
            walked = dsm.walk(obj.Config, listing, registry);
            document = nansen.internal.jsonRoundTrip(walked.toStruct());
            records = nansen.internal.asCellOfStructs(document.records);
            unmatched = nansen.internal.asCellOfStructs(document.unmatched);
            keyColumns = containers.Map("KeyType", "char", "ValueType", "any");
            for i = 1:numel(derived)
                plan = derived{i}{1};
                walkedPart = dsm.walk(obj.assignmentConfig(plan), dsm.Listing(derived{i}(2), listing.Environment), registry);
                part = nansen.internal.jsonRoundTrip(walkedPart.toStruct());
                partRecords = nansen.internal.asCellOfStructs(part.records);
                for j = 1:numel(partRecords)
                    record = partRecords{j};
                    below = string(record.entityType) == plan.entityType || hasParentOfType(record, plan.entityType);
                    if below
                        % the assigned entity, and what is below it
                        records = obj.mergeRecord(records, record, keyColumns, false);
                    else
                        % an entity above it: its folders are the walk of the rest's, so it adds only an entity not found
                        record.locations = {};
                        records = obj.mergeRecord(records, record, keyColumns, true);
                    end
                end
                unmatched = [unmatched, nansen.internal.asCellOfStructs(part.unmatched)]; %#ok<AGROW>
            end
            environment = listing.Environment;
            if environment == ""
                environment = obj.Environment;
            end
            stamp = string(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss"));
            result = nansen.Scan(records, unmatched, summary, environment, stamp);
        end

        % -- entries matched by hand ------------------------------------------------------

        function [path, level, entityType] = assignmentTarget(obj, dataLocation, path)
            %assignmentTarget An entry that can be matched to an entity: its path as a scan lists it,
            %   its level (1-based) and the entity type of that level
            parts = nansen.Dataset.entryParts(path);
            dataLocation = string(dataLocation);
            if ~ismember(dataLocation, obj.Config.locationIds())
                nansen.internal.throwError("unknown-location", "the dataset has no data location '%s'", dataLocation)
            end
            levels = obj.Config.layout(dataLocation);
            if numel(parts) > numel(levels)
                nansen.internal.throwError("invalid-params", "'%s' is deeper than the levels of '%s'", path, dataLocation)
            end
            level = numel(parts);
            entityType = string(nansen.internal.getField(levels{level}, "entityType", ""));
            if entityType == ""
                nansen.internal.throwError("invalid-params", "level '%s' of '%s' holds no entity type", ...
                    string(levels{level}.name), dataLocation)
            end
            path = strjoin(parts, "/");
            if string(nansen.internal.getField(levels{level}, "fileSystemType", "folder")) == "folder"
                path = path + "/";
            end
        end

        function typed = checkKey(obj, entityType, key)
            %checkKey The key of an entity of the type, its values typed by the key columns (invalid-params otherwise)
            columns = obj.keyColumns(entityType);
            names = [columns.Name];
            if isempty(columns)
                names = strings(1, 0);
            end
            given = strings(1, 0);
            if isstruct(key) && isscalar(key)
                given = reshape(string(fieldnames(key)), 1, []);
            end
            if ~(isstruct(key) && isscalar(key)) || ~isequal(sort(given), sort(names))
                nansen.internal.throwError("invalid-params", "the key of %s has the columns %s", entityType, strjoin(names, ", "))
            end
            typed = struct();
            for i = 1:numel(columns)
                name = names(i);
                value = key.(name);
                if columns(i).DataType == "integer"
                    if (ischar(value) || (isstring(value) && isscalar(value))) && ~isempty(regexp(char(value), '^\s*-?\d+\s*$', 'once'))
                        value = str2double(value);
                    end
                    if ~(isnumeric(value) && isscalar(value) && isreal(value) && isfinite(value) && value == round(value))
                        nansen.internal.throwError("invalid-params", "%s is an integer, not %s", name, jsonencode(key.(name)))
                    end
                    value = double(value);
                else
                    if ~((ischar(value) && (isrow(value) || isempty(value))) || (isstring(value) && isscalar(value))) ...
                            || strtrim(string(value)) == ""
                        nansen.internal.throwError("invalid-params", "%s is a text that is not empty, not %s", name, jsonencode(key.(name)))
                    end
                    value = char(strtrim(string(value)));
                end
                typed.(name) = value;
            end
        end

        function [entityType, key] = suggestedKey(obj, dataLocation, rootStoragePath, path)
            %suggestedKey For an entry a scan did not match: the entity type of its level and what the
            %   naming rules read of its key from its path (NaN, null in JSON, for a value they cannot
            %   read). Both NaN if it cannot be matched.
            entityType = NaN;
            key = NaN;
            try
                [relative, ~, target] = obj.assignmentTarget(dataLocation, path);
            catch err
                if isa(err, "nansen.NansenError")
                    return
                end
                rethrow(err)
            end
            if endsWith(relative, "/") ~= endsWith(string(path), "/")
                return   % a file where a folder is expected, or the reverse
            end
            try
                root = string(obj.Config.rootStoragePath(dataLocation, rootStoragePath).path);
            catch
                root = "";
            end
            fullPath = regexprep(root, "[/\\]+$", "") + "/" + regexprep(relative, "/$", "");
            registry = dsm.ExtractorRegistry();
            key = struct();
            seed = struct();
            for owner = [obj.ancestorTypes(target), target]
                values = struct();
                if ~isempty(obj.Config.rulesFor(dataLocation, owner))
                    try
                        values = dsm.internal.evaluateFields(obj.Config, dataLocation, char(relative), owner, seed, registry, fullPath);
                    catch
                        values = struct();   % a rule that cannot be read on this path reads nothing
                    end
                end
                for name = obj.identityKeys(owner)
                    value = nansen.internal.getField(values, name, []);
                    if dsm.internal.isNone(value)
                        key.(name) = NaN;
                    else
                        if isstring(value)
                            value = char(value);
                        end
                        key.(name) = value;
                        seed.(name) = value;
                    end
                end
            end
            entityType = char(target);
        end
    end

    methods (Access = private)
        function plans = assignmentPlans(obj, assignments)
            %assignmentPlans The assignments that still fit the config, with their path, level and typed key
            plans = {};
            for i = 1:numel(assignments)
                assignment = assignments{i};
                try
                    [path, level, entityType] = obj.assignmentTarget(string(assignment.dataLocation), string(assignment.path));
                    if entityType ~= string(assignment.entityType)
                        continue
                    end
                    key = obj.checkKey(entityType, assignment.key);
                catch err
                    if isa(err, "nansen.NansenError")
                        continue
                    end
                    rethrow(err)
                end
                plans{end + 1} = struct("dataLocation", string(assignment.dataLocation), "path", path, ...
                    "level", level, "entityType", entityType, "key", key); %#ok<AGROW>
            end
        end

        function [listing, derived] = splitListing(~, listing, plans)
            %splitListing The listing without the assigned entries and what lies below them; and for
            %   each assignment found in a root, {plan, a root of its entries (with the folders they are
            %   in)}. An entry belongs to the innermost assignment that holds it.
            roots = {};
            derived = {};
            for r = 1:numel(listing.Roots)
                root = listing.Roots{r};
                mine = plans(cellfun(@(p) p.dataLocation == string(root.DataLocation), plans));
                owned = repmat({{}}, 1, numel(mine));
                rest = {};
                for e = 1:numel(root.Entries)
                    entry = string(root.Entries{e});
                    best = 0;
                    for i = 1:numel(mine)
                        if isWithin(entry, mine{i}.path) && (best == 0 || strlength(mine{i}.path) > strlength(mine{best}.path))
                            best = i;
                        end
                    end
                    if best == 0
                        rest{end + 1} = root.Entries{e}; %#ok<AGROW>
                    else
                        owned{best}{end + 1} = root.Entries{e};
                    end
                end
                kept = root;
                kept.Entries = rest;
                roots{end + 1} = kept; %#ok<AGROW>
                for i = 1:numel(mine)
                    if ~isempty(owned{i})
                        derived{end + 1} = {mine{i}, dsm.Listing.makeRoot(root.DataLocation, root.RootStoragePath, owned{i})}; %#ok<AGROW>
                    end
                end
            end
            listing = dsm.Listing(roots, listing.Environment);
        end

        function config = assignmentConfig(obj, plan)
            %assignmentConfig The config with only the assignment's location, in which the names on its
            %   path are taken as they are and the fields of its key have the assigned values
            document = obj.Config.Document;
            location = obj.Config.location(plan.dataLocation);
            source = location.filesystemSource;
            names = split(regexprep(plan.path, "/$", ""), "/")';
            layout = obj.Config.layout(plan.dataLocation);
            for i = 1:plan.level
                level = layout{i};
                for field = {'excludePatterns', 'matchPattern', 'isVariable', 'fixedName'}
                    if isfield(level, field{1})
                        level = rmfield(level, field{1});
                    end
                end
                level.isVariable = false;
                level.fixedName = char(names(i));
                layout{i} = level;
            end
            source.entityLayout = layout;
            keyNames = reshape(string(fieldnames(plan.key)), 1, []);
            mapping = obj.Config.mapping(plan.dataLocation);
            mapping = mapping(cellfun(@(item) ~ismember(string(item.metadataRef), keyNames), mapping));
            for name = keyNames
                mapping{end + 1} = struct("metadataRef", char(name), ...
                    "extraction", struct("method", 'fixed', "value", plan.key.(name))); %#ok<AGROW>
            end
            source.metadataMapping = mapping;
            location.filesystemSource = source;
            document.dataLocations = {location};
            config = dsm.Config(document, obj.Config.Source);
        end

        function records = mergeRecord(obj, records, record, keyColumns, onlyNew)
            %mergeRecord Add a record found under an assigned entry to the record of the same entity, or as a new record
            entityType = string(record.entityType);
            if ~isKey(keyColumns, char(entityType))
                columns = obj.keyColumns(entityType);
                keyColumns(char(entityType)) = [columns.Name];
            end
            names = keyColumns(char(entityType));
            wanted = keyTextOf(obj.recordKey(record), names);
            index = 0;
            for i = 1:numel(records)
                if string(records{i}.entityType) == entityType && keyTextOf(obj.recordKey(records{i}), names) == wanted
                    index = i;
                    break
                end
            end
            if index == 0
                records{end + 1} = record;
                return
            end
            if onlyNew
                return
            end
            existing = records{index};
            issues = nansen.internal.asCellOfStructs(nansen.internal.getField(existing, "issues", {}));
            locations = nansen.internal.asCellOfStructs(existing.locations);
            for entry = nansen.internal.asCellOfStructs(record.locations)
                item = entry{1};
                slot = 0;
                for j = 1:numel(locations)
                    if string(locations{j}.dataLocationIdentifier) == string(item.dataLocationIdentifier) ...
                            && string(locations{j}.rootStoragePathIdentifier) == string(item.rootStoragePathIdentifier)
                        slot = j;
                        break
                    end
                end
                if slot == 0
                    locations{end + 1} = item; %#ok<AGROW>
                    continue
                end
                same = locations{slot};
                paths = unique([string(nansen.internal.asCellstr(same.paths)), string(nansen.internal.asCellstr(item.paths))]);
                same.paths = cellstr(paths);
                if isfield(item, "files")
                    files = nansen.internal.getField(same, "files", struct());
                    for name = reshape(string(fieldnames(item.files)), 1, [])
                        merged = [string(nansen.internal.asCellstr(nansen.internal.getField(files, name, {}))), ...
                            string(nansen.internal.asCellstr(item.files.(name)))];
                        files.(name) = cellstr(unique(merged));
                    end
                    same.files = files;
                end
                if isfield(item, "isComplete")
                    same.isComplete = logical(nansen.internal.getField(same, "isComplete", true)) && logical(item.isComplete);
                end
                if string(same.fileSystemType) == "folder" && numel(same.paths) > 1
                    issues{end + 1} = struct("code", 'duplicate-entity', "message", char(sprintf("%d folders in '%s' are this entity: %s", ...
                        numel(same.paths), string(same.dataLocationIdentifier), strjoin(string(same.paths), ", ")))); %#ok<AGROW>
                end
                locations{slot} = same;
            end
            order = obj.Config.locationIds();
            sortKeys = strings(1, numel(locations));
            for j = 1:numel(locations)
                sortKeys(j) = sprintf("%05d|%s", find(order == string(locations{j}.dataLocationIdentifier), 1), ...
                    string(locations{j}.rootStoragePathIdentifier));
            end
            [~, sorting] = sort(sortKeys);
            existing.locations = locations(sorting);
            for name = reshape(string(fieldnames(record.metadata)), 1, [])
                if ~isfield(existing.metadata, name)
                    existing.metadata.(name) = record.metadata.(name);
                end
            end
            for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(record, "issues", {}))
                code = string(entry{1}.code);
                message = string(nansen.internal.getField(entry{1}, "message", ""));
                known = any(cellfun(@(x) string(x.code) == code && string(nansen.internal.getField(x, "message", "")) == message, issues));
                if ismember(code, ["missing-required-file", "cardinality-violation"]) && ~known
                    issues{end + 1} = entry{1}; %#ok<AGROW>
                end
            end
            if ~isempty(issues)
                existing.issues = issues;
            end
            records{index} = existing;
        end
    end

    methods

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

        function parts = entryParts(path)
            %entryParts The names of an entry's path in a data location (invalid-params for none, or a '.' or '..')
            parts = reshape(split(replace(string(path), "\", "/"), "/"), 1, []);
            parts = parts(parts ~= "");
            if isempty(parts) || any(ismember(parts, [".", ".."]))
                nansen.internal.throwError("invalid-params", "'%s' is not a path in the data location", string(path))
            end
        end
    end
end

function tf = isWithin(entry, path)
    % Whether a listing entry is the entry at path, or below it (a folder's path ends with '/')
    tf = entry == path || (endsWith(path, "/") && startsWith(entry, path));
end

function tf = hasParentOfType(record, entityType)
    tf = false;
    for parent = nansen.internal.asCellOfStructs(nansen.internal.getField(record, "parents", {}))
        if string(parent{1}.entityType) == entityType
            tf = true;
            return
        end
    end
end

function text = keyTextOf(key, names)
    % The values of a key's columns as JSON text, to compare keys by (null for one it lacks)
    values = cell(1, numel(names));
    for i = 1:numel(names)
        values{i} = nansen.internal.getField(key, names(i), NaN);
    end
    text = string(jsonencode(values));
end
