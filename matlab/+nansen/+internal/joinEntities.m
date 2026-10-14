function entities = joinEntities(entityType, keyColumns, records, table, recordKey)
%joinEntities Table rows in table order, then entities found only in the stores, in walk order
%
%   records is a cell of DSM records (JSON form); table an nansen.EntityTable;
%   recordKey a function from a record to its key struct. Returns a cell row
%   of nansen.Entity. Records whose key cannot be completed come last, with
%   the issue incomplete-key.
    complete = false(1, numel(records));
    recordTexts = strings(1, numel(records));
    incomplete = {};
    for i = 1:numel(records)
        key = recordKey(records{i});
        present = false(1, numel(keyColumns));
        for c = 1:numel(keyColumns)
            present(c) = isfield(key, keyColumns(c)) && ~isempty(key.(keyColumns(c)));
        end
        if ~all(present)
            partial = struct();
            for name = keyColumns
                partial.(name) = nansen.internal.getField(key, name, []);
            end
            issue = struct("code", 'incomplete-key', "message", char("no value for " + strjoin(keyColumns(~present), ", ")));
            incomplete{end + 1} = nansen.Entity(entityType, partial, records{i}, [], {issue}); %#ok<AGROW>
            continue
        end
        complete(i) = true;
        recordTexts(i) = keyTextOf(key, keyColumns);
    end
    keyed = records(complete);
    recordTexts = recordTexts(complete);
    % When two records share a key, the last one is the one joined (ismember finds the first, so search reversed)
    count = numel(recordTexts);
    [~, lastOf] = ismember(recordTexts, flip(recordTexts));
    lastOf = count + 1 - lastOf;

    rows = table2struct(table.Data);
    rowTexts = strings(1, numel(rows));
    for i = 1:numel(rows)
        rowTexts(i) = keyTextOf(rows(i), keyColumns);
    end
    [joined, at] = ismember(rowTexts, flip(recordTexts));
    entities = cell(1, numel(rows));
    for i = 1:numel(rows)
        record = [];
        if joined(i)
            record = keyed{count + 1 - at(i)};
        end
        entities{i} = nansen.Entity(entityType, keyOf(rows(i), keyColumns), record, rows(i));
    end
    storeOnly = find(~ismember(recordTexts, rowTexts));
    extra = cell(1, numel(storeOnly));
    for j = 1:numel(storeOnly)
        record = keyed{lastOf(storeOnly(j))};
        extra{j} = nansen.Entity(entityType, keyOf(recordKey(record), keyColumns), record);
    end
    entities = [entities, extra, incomplete];
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
    text = string(nansen.internal.keyText(parts));
end
