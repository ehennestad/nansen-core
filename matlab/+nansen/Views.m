classdef Views
%Views Saved views of an entity type's table: which rows and columns to show
%
%   A view has a name, and any of: keys (the rows it holds, as dev's extra
%   metatables did), filters on columns, hiddenColumns and a search text.
%   The views of an entity type are kept in
%   views/<entityType>.views.nansen.json; the dashboard applies them, and
%   the table is not changed. Get one with project.views(entityType).
%   Python's nansen.views does the same.
%
%   Views are structs as decoded from JSON, with keys, filters and
%   hiddenColumns as cell rows (and each filter's values too), so they
%   write back as arrays however many items they have.

    properties (SetAccess = immutable)
        Path (1,1) string
        EntityType (1,1) string
        KeyNames (1,:) string
    end

    methods
        function obj = Views(path, entityType, keyNames)
            obj.Path = path;
            obj.EntityType = entityType;
            obj.KeyNames = reshape(string(keyNames), 1, []);
        end

        function views = list(obj)
            %list The views, in the order they were first saved (a cell row of structs)
            document = obj.read();
            views = document.views;
        end

        function view = save(obj, view)
            %save Add a view, or replace the one of the same name (keeping its place)
            if ~isstruct(view) || ~isscalar(view) || ~isfield(view, "name") || strtrim(string(view.name)) == ""
                nansen.internal.throwError("invalid-params", "a view needs a name")
            end
            view = nansen.Views.normalize(view);
            if isfield(view, "keys")
                for i = 1:numel(view.keys)
                    key = view.keys{i};
                    if ~isstruct(key) || ~isequal(sort(string(fieldnames(key)))', sort(obj.KeyNames))
                        nansen.internal.throwError("invalid-params", "a key of %s has the columns %s", ...
                            obj.EntityType, strjoin(obj.KeyNames, ", "))
                    end
                end
            end
            document = obj.read();
            if isfield(view, "default") && isequal(view.default, true)   % one default view: the others are not
                for i = 1:numel(document.views)
                    if isfield(document.views{i}, "default") && isequal(document.views{i}.default, true)
                        document.views{i}.default = false;
                    end
                end
            end
            names = string(cellfun(@(v) char(v.name), document.views, UniformOutput=false));   % a string array, also when empty
            at = find(names == string(view.name), 1);
            if isempty(at)
                document.views{end + 1} = view;
            else
                document.views{at} = view;
            end
            obj.write(document)
        end

        function remove(obj, name)
            document = obj.read();
            keep = cellfun(@(v) string(v.name) ~= string(name), document.views);
            if all(keep)
                nansen.internal.throwError("unknown-view", "%s has no view '%s'", obj.EntityType, name)
            end
            document.views = document.views(keep);
            obj.write(document)
        end
    end

    methods (Static)
        function tf = passes(value, filter)
            %passes Whether a value passes one filter of a view (as the dashboard applies them); none is [] or empty text
            if isstring(value) && isscalar(value) && ismissing(value)
                value = [];
            end
            none = isempty(value) || ((ischar(value) || isstring(value)) && strlength(string(value)) == 0) ...
                || (isnumeric(value) && isscalar(value) && isnan(value));
            switch string(filter.op)
                case "in"
                    tf = false;
                    for v = asCellRow(nansen.internal.getField(filter, "values", {}))
                        candidate = v{1};
                        if isempty(candidate) && ~ischar(candidate) && ~isstring(candidate)
                            tf = none;
                        else
                            tf = ~none && sameValue(candidate, value);
                        end
                        if tf
                            return
                        end
                    end
                case "range"
                    tf = ~none;
                    for bound = ["min", "max"]
                        if ~tf || ~isfield(filter, bound) || isempty(filter.(bound))
                            continue
                        end
                        b = filter.(bound);
                        if isnumeric(b) && isnumeric(value) && ~islogical(value)
                            ok = (bound == "min" && value >= b) || (bound == "max" && value <= b);
                        elseif (ischar(b) || isstring(b)) && (ischar(value) || isstring(value))
                            ok = (bound == "min" && string(value) >= string(b)) || (bound == "max" && string(value) <= string(b));
                        else
                            ok = false;
                        end
                        tf = ok;
                    end
                case "is"
                    tf = islogical(value) && isscalar(value) && value == logical(filter.value);
                case "contains"
                    tf = ~none && contains(lower(string(value)), lower(string(nansen.internal.getField(filter, "text", ""))));
                case "empty"
                    tf = none;
                case "notEmpty"
                    tf = ~none;
                otherwise
                    tf = true;
            end
        end

        function view = normalize(view)
            %normalize Give a decoded view the shapes that write back as JSON arrays
            if isfield(view, "keys")
                view.keys = nansen.internal.asCellOfStructs(view.keys);
            end
            if isfield(view, "filters")
                filters = nansen.internal.asCellOfStructs(view.filters);
                for i = 1:numel(filters)
                    if isfield(filters{i}, "values")
                        filters{i}.values = asCellRow(filters{i}.values);
                    end
                end
                view.filters = filters;
            end
            if isfield(view, "hiddenColumns")
                view.hiddenColumns = nansen.internal.asCellstr(view.hiddenColumns);
            end
            if isfield(view, "columnOrder")
                view.columnOrder = nansen.internal.asCellstr(view.columnOrder);
            end
        end
    end

    methods (Access = private)
        function document = read(obj)
            if ~isfile(obj.Path)
                entry = nansen.internal.schemaEntry("nansen.views");
                document = struct("schemaType", 'nansen.views', "schemaVersion", char(entry.version), ...
                    "entityType", char(obj.EntityType), "views", {{}});
                return
            end
            document = nansen.readDocument(obj.Path, ExpectedType="nansen.views");
            views = nansen.internal.asCellOfStructs(document.views);
            for i = 1:numel(views)
                views{i} = nansen.Views.normalize(views{i});
            end
            document.views = views;
        end

        function write(obj, document)
            folder = fileparts(obj.Path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            nansen.checkDocument(document, ExpectedType="nansen.views");
            nansen.internal.writeJson(obj.Path, document)
        end
    end
end

function items = asCellRow(value)
    % A decoded JSON array of scalars as a cell row: jsondecode makes ["a"] a cell, [1] a number and [true] a logical
    if iscell(value)
        items = reshape(value, 1, []);
    elseif ischar(value) || (isstring(value) && isscalar(value))
        items = {char(value)};
    elseif isempty(value)
        items = {};
    else
        items = num2cell(reshape(value, 1, []));
        for i = 1:numel(items)
            if isnumeric(items{i}) && isnan(items{i})
                items{i} = [];   % jsondecode makes null in a number array NaN
            end
        end
    end
end

function tf = sameValue(a, b)
    if (ischar(a) || isstring(a)) && (ischar(b) || isstring(b))
        tf = string(a) == string(b);
    elseif islogical(a) && islogical(b)
        tf = a == b;
    elseif isnumeric(a) && isnumeric(b) && ~islogical(a) && ~islogical(b)
        tf = a == b;
    else
        tf = false;
    end
end
