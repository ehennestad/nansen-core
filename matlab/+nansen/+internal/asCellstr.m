function items = asCellstr(value)
%asCellstr Normalise a decoded JSON array of strings to a row cell array of char
    if isempty(value)
        items = {};
    elseif iscell(value)
        items = reshape(value, 1, []);
    elseif ischar(value) || isstring(value)
        items = reshape(cellstr(value), 1, []);
    else
        error("nansen:internal:NotAStringArray", "Expected a JSON array of strings.")
    end
end
