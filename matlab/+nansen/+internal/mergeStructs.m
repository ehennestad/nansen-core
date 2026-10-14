function merged = mergeStructs(base, override)
%mergeStructs base with override's fields on top, recursing into fields that are structs on both sides
    merged = base;
    for name = reshape(string(fieldnames(override)), 1, [])
        value = override.(name);
        if isstruct(value) && isscalar(value) && isfield(merged, name) && isstruct(merged.(name)) && isscalar(merged.(name))
            merged.(name) = nansen.internal.mergeStructs(merged.(name), value);
        else
            merged.(name) = value;
        end
    end
end
