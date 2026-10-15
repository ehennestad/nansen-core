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
