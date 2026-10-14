function value = getField(s, name, default)
%getField Field of a struct, or a default when the field is absent
    if isstruct(s) && isfield(s, name)
        value = s.(name);
    else
        value = default;
    end
end
