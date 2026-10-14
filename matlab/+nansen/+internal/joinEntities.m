function entities = joinEntities(entityType, keyColumns, records, table, recordKey)
%joinEntities Table rows in table order, then entities found only in the stores, in walk order
%
%   records is a cell of DSM records (JSON form); table an nansen.EntityTable;
%   recordKey a function from a record to its key struct. Returns a cell row
%   of nansen.Entity. Records whose key cannot be completed come last, with
%   the issue incomplete-key.
    byKey = containers.Map("KeyType", "char", "ValueType", "any");
    order = {};
    incomplete = {};
    for i = 1:numel(records)
        key = recordKey(records{i});
        missing = keyColumns(~arrayfun(@(name) isfield(key, name) && ~isempty(key.(name)), keyColumns));
        if ~isempty(missing)
            partial = struct();
            for name = keyColumns
                partial.(name) = nansen.internal.getField(key, name, []);
            end
            issue = struct("code", 'incomplete-key', "message", char("no value for " + strjoin(missing, ", ")));
            incomplete{end + 1} = nansen.Entity(entityType, partial, records{i}, [], {issue}); %#ok<AGROW>
            continue
        end
        text = keyTextOf(key, keyColumns);
        byKey(text) = records{i};
        order{end + 1} = text; %#ok<AGROW>
    end

    entities = {};
    seen = containers.Map("KeyType", "char", "ValueType", "logical");
    rows = table2struct(table.Data);
    for i = 1:numel(rows)
        row = rows(i);
        text = keyTextOf(row, keyColumns);
        seen(text) = true;
        record = [];
        if isKey(byKey, text)
            record = byKey(text);
        end
        entities{end + 1} = nansen.Entity(entityType, keyOf(row, keyColumns), record, row); %#ok<AGROW>
    end
    for i = 1:numel(order)
        if ~isKey(seen, order{i})
            record = byKey(order{i});
            entities{end + 1} = nansen.Entity(entityType, keyOf(recordKey(record), keyColumns), record); %#ok<AGROW>
        end
    end
    entities = [entities, incomplete];
end

function key = keyOf(values, keyColumns)
    key = struct();
    for name = keyColumns
        key.(name) = values.(name);
    end
end

function text = keyTextOf(values, keyColumns)
    parts = cell(1, numel(keyColumns));
    for i = 1:numel(keyColumns)
        parts{i} = values.(keyColumns(i));
    end
    text = nansen.internal.keyText(parts);
end
