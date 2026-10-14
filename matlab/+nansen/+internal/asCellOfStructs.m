function items = asCellOfStructs(value)
%asCellOfStructs Normalise a decoded JSON array of objects to a row cell of scalar structs
%
%   jsondecode returns a struct array for a homogeneous object array, a cell
%   array for a heterogeneous one, a scalar struct for a one-element array,
%   and [] for an empty one. Callers should not have to care which.

    if isempty(value)
        items = {};
    elseif iscell(value)
        items = reshape(value, 1, []);
    elseif isstruct(value)
        items = num2cell(reshape(value, 1, []));
    else
        error("nansen:internal:NotAnObjectArray", "Expected a JSON array of objects.")
    end
end
