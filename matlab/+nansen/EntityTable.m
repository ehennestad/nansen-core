classdef EntityTable < handle
%EntityTable One entity type's authored values: a CSV plus a nansen.table sidecar
%
%   table = nansen.EntityTable.read(sidecarPath) reads a table, and
%   table = nansen.EntityTable(entityType, key, columns) makes an empty
%   one. Values live in the Data property, a MATLAB table with one variable
%   per column:
%
%     string            string        (<missing> when missing)
%     integer, number   double        (NaN)
%     boolean           logical       (never missing)
%     date, datetime    datetime      (NaT)
%
%   See docs/reference/table-format.md.

    properties (SetAccess = private)
        EntityType (1,1) string
        Key (1,:) string
        Columns (1,:) nansen.Column = nansen.Column.empty(1, 0)
        FragmentIds (1,:) string
        FragmentVersions (1,:) string
        File (1,1) string
        Revision (1,1) double = 0
        Path (1,1) string = ""
        Data table
    end

    properties
        % Values for columns a new row leaves out, by column name; filled
        % from fragment defaults.
        Defaults (1,1) struct = struct()
    end

    properties (Access = private)
        KeyIndex
    end

    methods
        function obj = EntityTable(entityType, key, columns, options)
            arguments
                entityType (1,1) string
                key (1,:) string
                columns (1,:) nansen.Column
                options.File (1,1) string = ""
                options.Revision (1,1) double = 0
                options.FragmentIds (1,:) string = string.empty(1, 0)
                options.FragmentVersions (1,:) string = string.empty(1, 0)
            end
            obj.EntityType = entityType;
            obj.Key = key;
            obj.Columns = columns;
            obj.File = options.File;
            if obj.File == ""
                obj.File = entityType + ".csv";
            end
            obj.Revision = options.Revision;
            obj.FragmentIds = options.FragmentIds;
            obj.FragmentVersions = options.FragmentVersions;
            obj.checkSpec()
            obj.Data = nansen.EntityTable.emptyData(columns);
            obj.KeyIndex = containers.Map("KeyType", "char", "ValueType", "double");
        end

        function names = columnNames(obj)
            names = [obj.Columns.Name];
        end

        function n = numRows(obj)
            n = height(obj.Data);
        end

        % -- rows ---------------------------------------------------------------------------

        function addRow(obj, row)
            %addRow Add a row given as a struct; left-out columns get their default or a missing value
            arguments
                obj
                row (1,1) struct
            end
            unknown = setdiff(string(fieldnames(row)), obj.columnNames());
            if ~isempty(unknown)
                error("nansen:EntityTable:UnknownColumn", "Unknown columns: %s", strjoin(unknown, ", "))
            end
            values = cell(1, numel(obj.Columns));
            for i = 1:numel(obj.Columns)
                column = obj.Columns(i);
                if isfield(row, column.Name)
                    value = row.(column.Name);
                elseif isfield(obj.Defaults, column.Name)
                    value = obj.Defaults.(column.Name);
                else
                    value = [];
                end
                values{i} = nansen.internal.checkValue(value, column, ismember(column.Name, obj.Key));
            end
            obj.appendRows(values, obj.numRows() + 2)
        end

        function row = getRow(obj, key)
            %getRow The row with this key, as a struct
            row = table2struct(obj.Data(obj.rowIndex(key), :));
        end

        function tf = hasRow(obj, key)
            tf = isKey(obj.KeyIndex, obj.normalizeKey(key));
        end

        function updateRow(obj, key, values)
            %updateRow Change non-key values of the row with this key, given as a struct
            arguments
                obj
                key
                values (1,1) struct
            end
            index = obj.rowIndex(key);
            for name = reshape(string(fieldnames(values)), 1, [])
                if ismember(name, obj.Key)
                    nansen.internal.throwError("read-only-column", "cannot change key column '%s'", name)
                end
                column = obj.column(name);
                obj.Data.(name)(index) = nansen.internal.checkValue(values.(name), column, false);
            end
        end

        function removeRow(obj, key)
            obj.Data(obj.rowIndex(key), :) = [];
            obj.rebuildIndex()
        end

        function addColumns(obj, columns, defaults, fragmentId, fragmentVersion)
            %addColumns Append columns, filling existing rows with each column's default
            arguments
                obj
                columns (1,:) nansen.Column
                defaults (1,1) struct = struct()
                fragmentId (1,1) string = ""
                fragmentVersion (1,1) string = ""
            end
            allColumns = [obj.Columns, columns];
            names = [allColumns.Name];
            if numel(unique(names)) < numel(names)
                nansen.internal.throwError("invalid-table-spec", "duplicate column names after adding %s", ...
                    strjoin([columns.Name], ", "))
            end
            filled = cell(1, numel(columns));
            for i = 1:numel(columns)
                value = nansen.internal.getField(defaults, columns(i).Name, []);
                filled{i} = nansen.internal.checkValue(value, columns(i), false);
            end
            for i = 1:numel(columns)
                name = char(columns(i).Name);
                if isempty(name)
                    error("nansen:EntityTable:EmptyColumnName", "Column %d of %d has no name (%s)", ...
                        i, numel(columns), jsonencode(arrayfun(@toStruct, columns, UniformOutput=false)))
                end
                obj.Data.(name) = repmat(filled{i}, obj.numRows(), 1);
                if isfield(defaults, columns(i).Name)
                    obj.Defaults.(columns(i).Name) = defaults.(columns(i).Name);
                end
            end
            obj.Columns = allColumns;
            if fragmentId ~= ""
                obj.FragmentIds(end + 1) = fragmentId;
                obj.FragmentVersions(end + 1) = fragmentVersion;
            end
        end

        % -- reading and writing --------------------------------------------------------

        function write(obj, sidecarPath)
            %write Save the CSV and sidecar; fails with revision-conflict if the file changed since it was read
            arguments
                obj
                sidecarPath (1,1) string = obj.Path
            end
            if sidecarPath == ""
                error("nansen:EntityTable:NoPath", "No path given and the table was not read from a file")
            end
            newRevision = obj.Revision;
            if isfile(sidecarPath)
                onDisk = nansen.internal.readJson(sidecarPath);
                diskRevision = nansen.internal.getField(onDisk, "revision", []);
                if ~(isnumeric(diskRevision) && isscalar(diskRevision) && diskRevision == obj.Revision)
                    nansen.internal.throwError("revision-conflict", ...
                        "%s has revision %s, this table was read at revision %d", ...
                        sidecarPath, mat2str(diskRevision), obj.Revision)
                end
                newRevision = obj.Revision + 1;
            end
            document = obj.toDocument();
            document.revision = newRevision;
            csvPath = fullfile(fileparts(sidecarPath), obj.File);
            nansen.internal.writeText(csvPath + ".tmp", obj.toCsv())
            nansen.internal.writeJson(sidecarPath + ".tmp", document)
            movefile(csvPath + ".tmp", csvPath, "f")
            movefile(sidecarPath + ".tmp", sidecarPath, "f")
            obj.Revision = newRevision;
            obj.Path = sidecarPath;
        end

        function text = toCsv(obj)
            %toCsv The table as CSV text, exactly as a writer produces it
            fields = strings(obj.numRows(), numel(obj.Columns));
            for i = 1:numel(obj.Columns)
                fields(:, i) = nansen.internal.encodeColumn(obj.Data.(obj.Columns(i).Name), obj.Columns(i));
            end
            lines = join(obj.columnNames(), ",");
            if obj.numRows() > 0
                lines = [lines; join(fields, ",", 2)];
            end
            text = join(lines, newline) + newline;
        end

        function document = toDocument(obj)
            %toDocument The sidecar as a struct, ready for jsonencode
            entry = nansen.internal.schemaEntry("nansen.table");
            document = struct( ...
                "schemaType", 'nansen.table', ...
                "schemaVersion", char(entry.version), ...
                "entityType", char(obj.EntityType), ...
                "file", char(obj.File), ...
                "revision", obj.Revision, ...
                "key", {cellstr(obj.Key)}, ...
                "columns", {arrayfun(@toStruct, obj.Columns, UniformOutput=false)});
            if ~isempty(obj.FragmentIds)
                document.fragments = arrayfun(@(id, version) struct("id", char(id), "version", char(version)), ...
                    obj.FragmentIds, obj.FragmentVersions, UniformOutput=false);
            end
        end

        function rows = toJsonRows(obj)
            %toJsonRows The rows as JSON values (the conformance output): a cell row of structs
            rows = cell(1, obj.numRows());
            for r = 1:obj.numRows()
                row = struct();
                for i = 1:numel(obj.Columns)
                    name = obj.Columns(i).Name;
                    row.(name) = nansen.internal.jsonValue(obj.Data.(name)(r), obj.Columns(i));
                end
                rows{r} = row;
            end
        end

        function row = jsonRow(obj, row)
            %jsonRow One row struct (as table2struct gives it) as JSON values
            for i = 1:numel(obj.Columns)
                name = obj.Columns(i).Name;
                row.(name) = nansen.internal.jsonValue(row.(name), obj.Columns(i));
            end
        end

        function column = column(obj, name)
            match = [obj.Columns.Name] == name;
            if ~any(match)
                error("nansen:EntityTable:UnknownColumn", "Unknown column '%s'", name)
            end
            column = obj.Columns(find(match, 1));
        end
    end

    methods (Static)
        function obj = read(sidecarPath)
            %read Read a table from its sidecar and the CSV next to it
            arguments
                sidecarPath (1,1) string
            end
            doc = nansen.readDocument(sidecarPath, ExpectedType="nansen.table");
            columns = cellfun(@nansen.Column.fromStruct, nansen.internal.asCellOfStructs(doc.columns), ...
                UniformOutput=false);
            fragments = nansen.internal.asCellOfStructs(nansen.internal.getField(doc, "fragments", []));
            asRow = @(values) reshape(string(values), 1, []);
            obj = nansen.EntityTable(string(doc.entityType), asRow(nansen.internal.asCellstr(doc.key)), ...
                [columns{:}], File=string(doc.file), Revision=doc.revision, ...
                FragmentIds=asRow(cellfun(@(f) f.id, fragments, UniformOutput=false)), ...
                FragmentVersions=asRow(cellfun(@(f) f.version, fragments, UniformOutput=false)));

            csvPath = fullfile(fileparts(sidecarPath), obj.File);
            [records, quoted] = nansen.internal.parseCsv(nansen.internal.readText(csvPath));
            header = string(records{1});
            if ~isequal(header, obj.columnNames())
                nansen.internal.throwError("header-mismatch", ...
                    "%s: header %s does not match the sidecar columns %s", ...
                    csvPath, strjoin(header, ","), strjoin(obj.columnNames(), ","))
            end
            isKeyColumn = ismember(obj.columnNames(), obj.Key);
            nColumns = numel(obj.Columns);
            values = cell(numel(records) - 1, nColumns);
            for r = 2:numel(records)
                record = records{r};
                if numel(record) ~= nColumns
                    nansen.internal.throwError("malformed-csv", "%s: record %d has %d fields, expected %d", ...
                        csvPath, r, numel(record), nColumns)
                end
                for i = 1:nColumns
                    where = sprintf("record %d, column '%s'", r, obj.Columns(i).Name);
                    values{r - 1, i} = nansen.internal.decodeCell(record{i}, quoted{r}(i), ...
                        obj.Columns(i), isKeyColumn(i), where);
                end
                obj.checkNewKey(values(r - 1, :), r)
                obj.KeyIndex(obj.keyOf(values(r - 1, :))) = r - 1;
            end
            obj.Data = nansen.EntityTable.buildData(values, obj.Columns);
            obj.Path = sidecarPath;
        end
    end

    methods (Access = private)
        function checkSpec(obj)
            names = obj.columnNames();
            [unique_names, firstIndex] = unique(names, "stable");
            if numel(unique_names) < numel(names)
                duplicates = names(setdiff(1:numel(names), firstIndex));
                nansen.internal.throwError("invalid-table-spec", "duplicate column names: %s", strjoin(unique(duplicates), ", "))
            end
            for name = obj.Key
                if ~ismember(name, names)
                    nansen.internal.throwError("invalid-table-spec", "key column '%s' is not among the columns", name)
                end
                if ~ismember(obj.column(name).DataType, ["string", "integer"])
                    nansen.internal.throwError("invalid-table-spec", "key column '%s' must be string or integer", name)
                end
            end
        end

        function text = keyOf(obj, rowValues)
            % rowValues: one cell per column, in column order
            text = nansen.internal.keyText(rowValues(ismember(obj.columnNames(), obj.Key)));
        end

        function checkNewKey(obj, rowValues, recordNumber)
            % Key columns appear in column order, which may differ from Key order; keyOf is consistent with itself.
            if isKey(obj.KeyIndex, obj.keyOf(rowValues))
                nansen.internal.throwError("duplicate-key", "record %d repeats the key of an earlier row", recordNumber)
            end
        end

        function appendRows(obj, rowValues, recordNumber)
            obj.checkNewKey(rowValues, recordNumber)
            obj.Data = [obj.Data; nansen.EntityTable.buildData(rowValues, obj.Columns)];
            obj.KeyIndex(obj.keyOf(rowValues)) = obj.numRows();
        end

        function text = normalizeKey(obj, key)
            % A key given as a struct of key columns, a cell array in Key order, or a scalar for one key column
            if isstruct(key)
                parts = arrayfun(@(name) key.(name), obj.Key, UniformOutput=false);
            elseif iscell(key)
                parts = key;
            elseif isscalar(key)
                parts = {key};
            else
                parts = num2cell(key);
            end
            if numel(parts) ~= numel(obj.Key)
                error("nansen:EntityTable:BadKey", "A key has %d values for this table", numel(obj.Key))
            end
            rowValues = cell(1, numel(obj.Columns));
            for i = 1:numel(obj.Key)
                [~, position] = ismember(obj.Key(i), obj.columnNames());
                rowValues{position} = nansen.internal.checkValue(parts{i}, obj.Columns(position), true);
            end
            text = obj.keyOf(rowValues);
        end

        function index = rowIndex(obj, key)
            text = obj.normalizeKey(key);
            if ~isKey(obj.KeyIndex, text)
                error("nansen:EntityTable:NoSuchRow", "No row with this key")
            end
            index = obj.KeyIndex(text);
        end

        function rebuildIndex(obj)
            obj.KeyIndex = containers.Map("KeyType", "char", "ValueType", "double");
            keyColumns = obj.columnNames();
            keyColumns = keyColumns(ismember(keyColumns, obj.Key));
            for r = 1:obj.numRows()
                parts = arrayfun(@(name) obj.Data.(name)(r), keyColumns, UniformOutput=false);
                obj.KeyIndex(nansen.internal.keyText(parts)) = r;
            end
        end
    end

    methods (Static, Access = private)
        function data = emptyData(columns)
            data = nansen.EntityTable.buildData(cell(0, numel(columns)), columns);
        end

        function data = buildData(values, columns)
            % values: one row per table row, one cell per column, each holding a typed scalar
            nRows = size(values, 1);
            data = table('Size', [nRows, numel(columns)], ...
                'VariableTypes', arrayfun(@nansen.EntityTable.variableType, columns, UniformOutput=false), ...
                'VariableNames', cellstr([columns.Name]));
            [dateFormat, datetimeFormat] = nansen.internal.dateFormats();
            for i = 1:numel(columns)
                name = columns(i).Name;
                if nRows > 0
                    data.(name) = vertcat(values{:, i});
                end
                switch columns(i).DataType
                    case "date"
                        data.(name).Format = dateFormat;
                    case "datetime"
                        data.(name).Format = datetimeFormat;
                end
            end
        end

        function type = variableType(column)
            switch column.DataType
                case "string"
                    type = 'string';
                case {"integer", "number"}
                    type = 'double';
                case "boolean"
                    type = 'logical';
                otherwise
                    type = 'datetime';
            end
        end
    end
end
