function id = runKeyId(key)
%runKeyId One char id for an entity key struct, whatever order its fields are in (for lookups)
    names = sort(string(fieldnames(key)))';
    parts = strings(1, numel(names));
    for i = 1:numel(names)
        value = key.(names(i));
        if isnumeric(value)
            value = sprintf('%d', value);
        end
        parts(i) = names(i) + "=" + string(value);
    end
    id = char(strjoin(parts, char(31)));
end
