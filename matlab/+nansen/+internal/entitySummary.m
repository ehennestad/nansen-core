function summary = entitySummary(entity, table)
%entitySummary The JSON form of an entity: the conformance output and the API's
%
%   With an nansen.EntityTable, values holds the row in JSON form ([] when
%   the entity has no row).
    locations = struct();
    for entry = entity.locations()
        locations.(entry{1}.dataLocationIdentifier) = sort(string(nansen.internal.asCellstr(entry{1}.paths)));
    end
    for name = reshape(string(fieldnames(locations)), 1, [])
        locations.(name) = cellstr(locations.(name));
    end
    summary = struct("key", entity.Key, "inStore", entity.inStore(), "inTable", entity.inTable(), ...
        "attributes", entity.attributes(), "locations", locations);
    if ~isempty(entity.Issues)
        summary.issues = cellstr(entity.issueCodes());
    end
    if nargin > 1
        summary.values = [];
        if entity.inTable()
            summary.values = table.jsonRow(entity.Row);
        end
    end
end
