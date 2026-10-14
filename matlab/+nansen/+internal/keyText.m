function text = keyText(values)
%keyText One char key for a row's key values (strings or integers), for lookups
    parts = cell(1, numel(values));
    for i = 1:numel(values)
        value = values{i};
        if isstring(value) || ischar(value)
            parts{i} = char(value);
        else
            parts{i} = sprintf('%d', value);
        end
    end
    text = strjoin(parts, char(31));
end
